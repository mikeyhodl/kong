local helpers = require "spec.helpers"

for _, strategy in helpers.each_strategy() do
describe("Proxy error handlers", function()
  local proxy_client

  lazy_setup(function()
    helpers.get_db_utils(strategy, {})
    assert(helpers.start_kong {
      nginx_conf = "spec/fixtures/custom_nginx.template",
    })
  end)

  lazy_teardown(function()
    helpers.stop_kong()
  end)

  before_each(function()
    proxy_client = helpers.proxy_client()
  end)

  after_each(function()
    if proxy_client then
      proxy_client:close()
    end
  end)

  it("HTTP 400", function()
    local res = assert(proxy_client:send {
      method = "GET",
      path = "/",
      headers = {
        ["X-Large"] = string.rep("a", 2^10 * 10), -- default large_client_header_buffers is 8k
      }
    })
    assert.res_status(400, res)
    local body = res:read_body()
    assert.matches("kong/", res.headers.server, nil, true)
    assert.matches("Request header or cookie too large", body)
  end)

  it("Request For Routers With Trace Method Not Allowed", function ()
    local res = assert(proxy_client:send {
      method = "TRACE",
      path = "/",
    })
    assert.res_status(405, res)
    local body = res:read_body()
    assert.matches("kong/", res.headers.server, nil, true)
    assert.matches("Method not allowed\nrequest_id: %x+\n", body)
  end)
end)
end
