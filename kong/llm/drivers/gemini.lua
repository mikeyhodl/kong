local _M = {}

-- imports
local cjson = require("cjson.safe")
local fmt = string.format
local ai_shared = require("kong.llm.drivers.shared")
local socket_url = require("socket.url")
local string_gsub = string.gsub
local buffer = require("string.buffer")
local table_insert = table.insert
local string_lower = string.lower
local ai_plugin_ctx = require("kong.llm.plugin.ctx")
local ai_plugin_base = require("kong.llm.plugin.base")
local pl_string = require "pl.stringx"

--

-- globals
local DRIVER_NAME = "gemini"
local get_global_ctx, _ = ai_plugin_ctx.get_global_accessors(DRIVER_NAME)
--

local _OPENAI_ROLE_MAPPING = {
  ["system"] = "system",
  ["user"] = "user",
  ["assistant"] = "model",
}

local function to_gemini_generation_config(request_table)
  return {
    ["maxOutputTokens"] = request_table.max_tokens,
    ["stopSequences"] = request_table.stop,
    ["temperature"] = request_table.temperature,
    ["topK"] = request_table.top_k,
    ["topP"] = request_table.top_p,
  }
end

local function is_content_safety_failure(content)
  return content
          and content.candidates
          and #content.candidates > 0
          and content.candidates[1].finishReason
          and content.candidates[1].finishReason == "SAFETY"
end

local function is_response_content(content)
  return content
        and content.candidates
        and #content.candidates > 0
        and content.candidates[1].content
        and content.candidates[1].content.parts
        and #content.candidates[1].content.parts > 0
        and content.candidates[1].content.parts[1].text
end

local function is_tool_content(content)
  return content
        and content.candidates
        and #content.candidates > 0
        and content.candidates[1].content
        and content.candidates[1].content.parts
        and #content.candidates[1].content.parts > 0
        and content.candidates[1].content.parts[1].functionCall
end

local function is_function_call_message(message)
  return message
        and message.role
        and message.role == "assistant"
        and message.tool_calls
        and type(message.tool_calls) == "table"
        and #message.tool_calls > 0
end

local function has_finish_reason(event)
  return event
         and event.candidates
         and #event.candidates > 0
         and event.candidates[1].finishReason
         or nil
end

local function handle_stream_event(event_t, model_info, route_type)
  -- discard empty frames, it should either be a random new line, or comment
  if (not event_t.data) or (#event_t.data < 1) then
    return
  end

  if event_t.data == ai_shared._CONST.SSE_TERMINATOR then
    return ai_shared._CONST.SSE_TERMINATOR, nil, nil
  end

  local event, err = cjson.decode(event_t.data)
  if err then
    ngx.log(ngx.WARN, "failed to decode stream event frame from gemini: ", err)
    return nil, "failed to decode stream event frame from gemini", nil
  end

  local finish_reason = has_finish_reason(event)  -- may be nil

  if is_response_content(event) then
    local metadata = {}
    metadata.finish_reason     = finish_reason
    metadata.completion_tokens = event.usageMetadata and event.usageMetadata.candidatesTokenCount or 0
    metadata.prompt_tokens     = event.usageMetadata and event.usageMetadata.promptTokenCount or 0

    local new_event = {
      choices = {
        [1] = {
          delta = {
            content = event.candidates[1].content.parts[1].text or "",
            role = "assistant",
          },
          index = 0,
          finish_reason = finish_reason
        },
      },
    }

    return cjson.encode(new_event), nil, metadata
  
  elseif is_tool_content(event) then
    local metadata = {}
    metadata.finish_reason     = finish_reason
    metadata.completion_tokens = event.usageMetadata and event.usageMetadata.candidatesTokenCount or 0
    metadata.prompt_tokens     = event.usageMetadata and event.usageMetadata.promptTokenCount or 0

    if event.candidates and #event.candidates > 0 then
      local new_event = {
        choices = {
          [1] = {
            delta = {
              tool_calls = {},
            },
            index = 0,
            finish_reason = finish_reason
          },
        },
      }

      local function_call_responses = event.candidates[1].content.parts

      if function_call_responses and #function_call_responses > 0 then
        for i, v in ipairs(function_call_responses) do
          new_event.choices[1].delta.tool_calls[i] = {
            ['function'] = {
              name = v.functionCall.name,
              arguments = cjson.encode(v.functionCall.args),
            },
            ['type'] = "function",
          }
        end
      end

      return cjson.encode(new_event), nil, metadata
    end


  end
end

local function to_tools(in_tools)
  if not in_tools then
    return nil
  end

  local out_tools

  for i, v in ipairs(in_tools) do
    if v['function'] then
      out_tools = out_tools or {
        [1] = {
          function_declarations = {}
        }
      }

      out_tools[1].function_declarations[i] = v['function']
    end
  end

  return out_tools
end


local function image_url_to_components(img)
  -- determine the protocol from the first 10 bytes
  if #img < 10 then
    return nil, "image URL is less than 10 bytes, which is not parsable"
  end

  -- capture only 10 bytes for the 'protocol://' to increase performance
  local protocol_parts = pl_string.split(img:sub(1, 6), ":")

  if protocol_parts then
    local protocol = protocol_parts[1]

    -- if the protocol is "data" then we can parse it,
    -- otherwise just send it as-is, because it's probably
    -- as GCP bucket or https link.
    if protocol == "data" then
      local coordinates_outer = pl_string.split(img:sub(#protocol+2), ";")
      local coordinates_inner = pl_string.split(coordinates_outer[2], ",")

      return {
        mimetype = coordinates_outer[1],
        encoding = coordinates_inner[1],
        data = coordinates_inner[2],
      }
    else
      return img
    end
  end

  return nil, "unable to determine the PROTOCOL from the image url"
end

-- expects nil return if part does not match expected format or cannot be transformed
local function openai_part_to_gemini_part(openai_part)
  if not openai_part then
    return nil
  end

  local gemini_part

  if openai_part.type and openai_part.type == "image_url" then
    if not (openai_part.image_url and openai_part.image_url.url) then
      return nil, "message part type is 'image_url' but is missing .image_url.url block"
    end

    local image_components, err = image_url_to_components(openai_part.image_url.url)
    if err then
      return nil, "could not decode OpenAI image-part, " .. err
    end

    if image_components and type(image_components) == "table" then
      gemini_part = {
        inlineData = {
          data = image_components.data,
          mimeType = image_components.mimetype,
        }
      }

    elseif image_components and type(image_components) == "string" then
      gemini_part = {
        fileData = {
          fileUri = image_components,
          mimeType = "image/generic",
        }
      }

    end

  elseif openai_part.type and openai_part.type == "text" then
    if not openai_part.text then
      return nil, "message part type is 'text' but is missing .text block"
    end

    gemini_part = {
      text = openai_part.text,
    }

  else
    return nil, "cannot transform part of type '" .. openai_part.type .. "' to Gemini format"
  end

  return gemini_part
end

local function to_gemini_chat_openai(request_table, model_info, route_type)
  local new_r = {}

  if request_table then
    if request_table.messages and #request_table.messages > 0 then
      local system_prompt

      for i, v in ipairs(request_table.messages) do

        -- for 'system', we just concat them all into one Gemini instruction
        if v.role and v.role == "system" then
          system_prompt = system_prompt or buffer.new()
          system_prompt:put(v.content or "")

        elseif v.role and v.role == "tool" then
          -- handle tool execution output
          table_insert(new_r.contents, {
            role = "function",
            parts = {
              {
                function_response = {
                  response = {
                    content = {
                      v.content,
                    },
                  },
                  name = "get_product_info",
                },
              },
            },
          })

        elseif is_function_call_message(v) then
          -- treat specific 'assistant function call' tool execution input message
          local function_calls = {}
          for i, t in ipairs(v.tool_calls) do
            function_calls[i] = {
              function_call = {
                name = t['function'].name,
              },
            }
          end

          table_insert(new_r.contents, {
            role = "function",
            parts = function_calls,
          })

        else
          local this_parts = {}

          -- for any other role, just construct the chat history as 'parts' type
          new_r.contents = new_r.contents or {}

          if type(v.content) == "string" then
            this_parts = {
              {
                text = v.content,
              },
            }

          elseif type(v.content) == "table" then
            if #v.content > 0 then  -- check it has ome kind of array element
              for j, part in ipairs(v.content) do
                local this_part, err = openai_part_to_gemini_part(part)
                
                if not this_part then
                  if not err then
                    err = "message at position " .. i .. ", part at position " .. j .. " does not match expected OpenAI format"
                  end
                  return nil, nil, err
                end

                this_parts[j] = this_part
              end
            else
              return nil, nil, "message at position " .. i .. " does not match expected array format"
            end
          end

          table_insert(new_r.contents, {
            role = _OPENAI_ROLE_MAPPING[v.role or "user"],  -- default to 'user'
            parts = this_parts,
          })
        end

      end

      -- This was only added in Gemini 1.5
      if system_prompt and model_info.name:sub(1, 10) == "gemini-1.0" then
        return nil, nil, "system prompts aren't supported on gemini-1.0 models"

      elseif system_prompt then
        new_r.systemInstruction = {
          parts = {
            {
              text = system_prompt:get(),
            },
          },
        }
      end
    end

    new_r.generationConfig = to_gemini_generation_config(request_table)

    -- handle function calling translation from OpenAI format
    new_r.tools = request_table.tools and to_tools(request_table.tools)
    new_r.tool_config = request_table.tool_config
  end

  return new_r, "application/json", nil
end

local function from_gemini_chat_openai(response, model_info, route_type)
  local err
  if response and (type(response) == "string") then
    response, err = cjson.decode(response)
  end

  if err then
    local err_client = "failed to decode response from Gemini"
    ngx.log(ngx.ERR, fmt("%s: %s", err_client, err))
    return nil, err_client
  end

  -- messages/choices table is only 1 size, so don't need to static allocate
  local messages = {}
  messages.choices = {}

  if response.candidates and #response.candidates > 0 then
    -- for transformer plugins only
    if is_content_safety_failure(response) and
      (ai_plugin_base.has_filter_executed("ai-request-transformer-transform-request") or
        ai_plugin_base.has_filter_executed("ai-response-transformer-transform-response")) then

      local err = "transformation generation candidate breached Gemini content safety"
      ngx.log(ngx.ERR, err)

      return nil, err

    elseif is_response_content(response) then
      messages.choices[1] = {
        index = 0,
        message = {
          role = "assistant",
          content = response.candidates[1].content.parts[1].text,
        },
        finish_reason = string_lower(response.candidates[1].finishReason),
      }
      messages.object = "chat.completion"
      messages.model = model_info.name

    elseif is_tool_content(response) then
      messages.choices[1] = {
        index = 0,
        message = {
          role = "assistant",
          tool_calls = {},
        },
      }

      local function_call_responses = response.candidates[1].content.parts
      for i, v in ipairs(function_call_responses) do
        messages.choices[1].message.tool_calls[i] =
          {
            ['function'] = {
              name = v.functionCall.name,
              arguments = cjson.encode(v.functionCall.args),
            },
          }
      end
    end

    -- process analytics
    if response.usageMetadata then
      messages.usage = {
        prompt_tokens = response.usageMetadata.promptTokenCount,
        completion_tokens = response.usageMetadata.candidatesTokenCount,
        total_tokens = response.usageMetadata.totalTokenCount,
      }
    end

  else -- probably a server fault or other unexpected response
    local err = "no generation candidates received from Gemini, or max_tokens too short"
    ngx.log(ngx.ERR, err)
    return nil, err

  end

  return cjson.encode(messages)
end

local transformers_to = {
  ["llm/v1/chat"] = to_gemini_chat_openai,
}

local transformers_from = {
  ["llm/v1/chat"] = from_gemini_chat_openai,
  ["stream/llm/v1/chat"] = handle_stream_event,
}

function _M.from_format(response_string, model_info, route_type)
  ngx.log(ngx.DEBUG, "converting from ", model_info.provider, "://", route_type, " type to kong")

  -- MUST return a string, to set as the response body
  if not transformers_from[route_type] then
    return nil, fmt("no transformer available from format %s://%s", model_info.provider, route_type)
  end

  local ok, response_string, err, metadata = pcall(transformers_from[route_type], response_string, model_info, route_type)
  if not ok then
    err = response_string
  end
  if err then
    return nil, fmt("transformation failed from type %s://%s: %s",
                    model_info.provider,
                    route_type,
                    err or "unexpected_error"
                  )
  end

  return response_string, nil, metadata
end

function _M.to_format(request_table, model_info, route_type)
  ngx.log(ngx.DEBUG, "converting from kong type to ", model_info.provider, "/", route_type)

  if route_type == "preserve" then
    -- do nothing
    return request_table, nil, nil
  end

  if not transformers_to[route_type] then
    return nil, nil, fmt("no transformer for %s://%s", model_info.provider, route_type)
  end

  request_table = ai_shared.merge_config_defaults(request_table, model_info.options, model_info.route_type)

  local ok, response_object, content_type, err = pcall(
    transformers_to[route_type],
    request_table,
    model_info
  )
  if err or (not ok) then
    return nil, nil, fmt("error transforming to %s://%s: %s", model_info.provider, route_type, err)
  end

  return response_object, content_type, nil
end

function _M.subrequest(body, conf, http_opts, return_res_table, identity_interface)
  -- use shared/standard subrequest routine
  local body_string, err

  if type(body) == "table" then
    body_string, err = cjson.encode(body)
    if err then
      return nil, nil, "failed to parse body to json: " .. err
    end
  elseif type(body) == "string" then
    body_string = body
  else
    return nil, nil, "body must be table or string"
  end

  local operation = get_global_ctx("stream_mode") and "streamGenerateContent"
                                                             or "generateContent"
  local f_url = conf.model.options and conf.model.options.upstream_url

  if not f_url then  -- upstream_url override is not set
    -- check if this is "public" or "vertex" gemini deployment
    if conf.model.options
        and conf.model.options.gemini
        and conf.model.options.gemini.api_endpoint
        and conf.model.options.gemini.project_id
        and conf.model.options.gemini.location_id
    then
      -- vertex mode
      f_url = fmt(ai_shared.upstream_url_format["gemini_vertex"],
                  conf.model.options.gemini.api_endpoint) ..
              fmt(ai_shared.operation_map["gemini_vertex"][conf.route_type].path,
                  conf.model.options.gemini.project_id,
                  conf.model.options.gemini.location_id,
                  conf.model.name,
                  operation)
    else
      -- public mode
      f_url = ai_shared.upstream_url_format["gemini"] ..
              fmt(ai_shared.operation_map["gemini"][conf.route_type].path,
                  conf.model.name,
                  operation)
    end
  end

  local method = ai_shared.operation_map[DRIVER_NAME][conf.route_type].method

  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
  }

  if identity_interface and identity_interface.interface then
    if identity_interface.interface:needsRefresh() then
      -- HACK: A bug in lua-resty-gcp tries to re-load the environment
      --       variable every time, which fails in nginx
      --       Create a whole new interface instead.
      --       Memory leaks are mega unlikely because this should only
      --       happen about once an hour, and the old one will be
      --       cleaned up anyway.
      local service_account_json = identity_interface.interface.service_account_json
      identity_interface.interface.token = identity_interface.interface:new(service_account_json).token

      kong.log.debug("gcp identity token for ", kong.plugin.get_id(), " has been refreshed")
    end

    headers["Authorization"] = "Bearer " .. identity_interface.interface.token

  elseif conf.auth and conf.auth.header_name then
    headers[conf.auth.header_name] = conf.auth.header_value
  end

  local res, err, httpc = ai_shared.http_request(f_url, body_string, method, headers, http_opts, return_res_table)
  if err then
    return nil, nil, "request to ai service failed: " .. err
  end

  if return_res_table then
    return res, res.status, nil, httpc
  else
    -- At this point, the entire request / response is complete and the connection
    -- will be closed or back on the connection pool.
    local status = res.status
    local body   = res.body

    if status > 299 then
      return body, res.status, "status code " .. status
    end

    return body, res.status, nil
  end
end

function _M.header_filter_hooks(body)
  -- nothing to parse in header_filter phase
end

function _M.post_request(conf)
  if ai_shared.clear_response_headers[DRIVER_NAME] then
    for i, v in ipairs(ai_shared.clear_response_headers[DRIVER_NAME]) do
      kong.response.clear_header(v)
    end
  end
end

function _M.pre_request(conf, body)
  -- disable gzip for gemini because it breaks streaming
  kong.service.request.set_header("Accept-Encoding", "identity")

  return true, nil
end

-- returns err or nil
function _M.configure_request(conf, identity_interface)
  local model = ai_plugin_ctx.get_request_model_table_inuse()
  if not model or type(model) ~= "table" or model.provider ~= DRIVER_NAME then
    return nil, "invalid model parameter"
  end

  local parsed_url
  local operation = get_global_ctx("stream_mode") and "streamGenerateContent"
                                                             or "generateContent"
  local f_url = model.options and model.options.upstream_url

  if not f_url then  -- upstream_url override is not set
    -- check if this is "public" or "vertex" gemini deployment
    if model.options
        and model.options.gemini
        and model.options.gemini.api_endpoint
        and model.options.gemini.project_id
        and model.options.gemini.location_id
    then
      -- vertex mode
      f_url = fmt(ai_shared.upstream_url_format["gemini_vertex"],
                  model.options.gemini.api_endpoint) ..
              fmt(ai_shared.operation_map["gemini_vertex"][conf.route_type].path,
                  model.options.gemini.project_id,
                  model.options.gemini.location_id,
                  model.name,
                  operation)
    else
      -- public mode
      f_url = ai_shared.upstream_url_format["gemini"] ..
              fmt(ai_shared.operation_map["gemini"][conf.route_type].path,
                  model.name,
                  operation)
    end
  end

  parsed_url = socket_url.parse(f_url)

  if model.options and model.options.upstream_path then
    -- upstream path override is set (or templated from request params)
    parsed_url.path = model.options.upstream_path
  end

  ai_shared.override_upstream_url(parsed_url, conf, model)


  -- if the path is read from a URL capture, ensure that it is valid
  parsed_url.path = (parsed_url.path and string_gsub(parsed_url.path, "^/*", "/")) or "/"

  kong.service.request.set_path(parsed_url.path)
  kong.service.request.set_scheme(parsed_url.scheme)
  kong.service.set_target(parsed_url.host, (tonumber(parsed_url.port) or 443))

  local auth_header_name = conf.auth and conf.auth.header_name
  local auth_header_value = conf.auth and conf.auth.header_value
  local auth_param_name = conf.auth and conf.auth.param_name
  local auth_param_value = conf.auth and conf.auth.param_value
  local auth_param_location = conf.auth and conf.auth.param_location

  -- DBO restrictions makes sure that only one of these auth blocks runs in one plugin config
  if auth_header_name and auth_header_value then
    kong.service.request.set_header(auth_header_name, auth_header_value)
  end

  if auth_param_name and auth_param_value and auth_param_location == "query" then
    local query_table = kong.request.get_query()
    query_table[auth_param_name] = auth_param_value
    kong.service.request.set_query(query_table)
  end
  -- if auth_param_location is "form", it will have already been set in a global pre-request hook

  -- if we're passed a GCP SDK, for cloud identity / SSO, use it appropriately
  if identity_interface then
    if identity_interface:needsRefresh() then
      -- HACK: A bug in lua-resty-gcp tries to re-load the environment
      --       variable every time, which fails in nginx
      --       Create a whole new interface instead.
      --       Memory leaks are mega unlikely because this should only
      --       happen about once an hour, and the old one will be
      --       cleaned up anyway.
      local service_account_json = identity_interface.service_account_json
      local identity_interface_new = identity_interface:new(service_account_json)
      identity_interface.token = identity_interface_new.token

      kong.log.debug("gcp identity token for ", kong.plugin.get_id(), " has been refreshed")
    end

    kong.service.request.set_header("Authorization", "Bearer " .. identity_interface.token)
  end

  return true
end


if _G._TEST then
  -- export locals for testing
  _M._to_tools = to_tools
  _M._to_gemini_chat_openai = to_gemini_chat_openai
  _M._from_gemini_chat_openai = from_gemini_chat_openai
  _M._openai_part_to_gemini_part = openai_part_to_gemini_part
end


return _M
