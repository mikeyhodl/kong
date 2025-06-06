local logger       = require "kong.cmd.utils.log"
local pgmoon       = require "pgmoon"
local arrays       = require "pgmoon.arrays"
local semaphore    = require "ngx.semaphore"
local kong_global  = require "kong.global"
local constants    = require "kong.constants"
local db_utils     = require "kong.db.utils"


local setmetatable = setmetatable
local encode_array = arrays.encode_array
local tonumber     = tonumber
local tostring     = tostring
local concat       = table.concat
local ipairs       = ipairs
local pairs        = pairs
local error        = error
local floor        = math.floor
local type         = type
local ngx          = ngx
local timer_every  = ngx.timer.every
local get_phase    = ngx.get_phase
local null         = ngx.null
local now          = ngx.now
local log          = ngx.log
local match        = string.match
local fmt          = string.format
local sub          = string.sub
local utils_toposort = db_utils.topological_sort
local insert       = table.insert
local table_merge  = require("kong.tools.table").table_merge
local strip        = require("kong.tools.string").strip
local now_updated  = require("kong.tools.time").get_updated_now


local WARN                          = ngx.WARN
local SQL_INFORMATION_SCHEMA_TABLES = [[
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = CURRENT_SCHEMA;
]]
local PROTECTED_TABLES = {
  schema_migrations = true,
  schema_meta       = true,
  locks             = true,
  parameters        = true,
}
local OPERATIONS = {
  read  = true,
  write = true,
}
local ADMIN_API_PHASE = kong_global.phases.admin_api
local CORE_ENTITIES = constants.CORE_ENTITIES


local function iterator(rows)
  local i = 0
  return function()
    i = i + 1
    return rows[i]
  end
end


local function get_table_names(self, excluded)
  local i = 0
  local table_names = {}
  for row, err in self:iterate(SQL_INFORMATION_SCHEMA_TABLES) do
    if err then
      return nil, err
    end

    if not excluded or not excluded[row.table_name] then
      i = i + 1
      table_names[i] = self:escape_identifier(row.table_name)
    end
  end

  return table_names
end


local get_names_of_tables_with_ttl
do
  local CORE_SCORE = {}
  for _, v in ipairs(CORE_ENTITIES) do
    CORE_SCORE[v] = 1
  end
  CORE_SCORE["workspaces"] = 2


  local function sort_core_tables_first(a, b)
    local sa = CORE_SCORE[a] or 0
    local sb = CORE_SCORE[b] or 0
    if sa == sb then
      -- sort tables in reverse order so that they end up sorted alphabetically,
      -- because utils_topological sort does "dependencies first" and then current.
      return a > b
    end
    return sa < sb
  end

  local sort = table.sort
  get_names_of_tables_with_ttl = function(strategies)
    local s
    local ttl_schemas_by_name = {}
    local table_names = {}
    for _, strategy in pairs(strategies) do
      s = strategy.schema
      if s.ttl then
        table_names[#table_names + 1] = s.name
        ttl_schemas_by_name[s.name] = s
      end
    end

    sort(table_names, sort_core_tables_first)

    local get_table_name_neighbors = function(table_name)
      local neighbors = {}
      local neighbors_len = 0
      local neighbor
      local schema = ttl_schemas_by_name[table_name]

      for _, field in schema:each_field() do
        if field.type == "foreign" and field.schema.ttl then
          neighbor = field.reference
          if ttl_schemas_by_name[neighbor] then -- the neighbor schema name is on table_names
            neighbors_len = neighbors_len + 1
            neighbors[neighbors_len] = neighbor
          end
          -- else the neighbor points to an unknown/uninteresting schema. This happens in tests.
        end
      end

      return neighbors
    end

    local res, err = utils_toposort(table_names, get_table_name_neighbors)

    if res then
      insert(res, 1, "clustering_rpc_requests")
      insert(res, 1, "cluster_events")
    end

    return res, err
  end
end


local function reset_schema(self)
  local table_names, err = get_table_names(self)
  if not table_names then
    return nil, err
  end

  local drop_tables
  if #table_names == 0 then
    drop_tables = ""
  else
    drop_tables = concat {
      "    DROP TABLE IF EXISTS ", concat(table_names, ", "), " CASCADE;\n"
    }
  end

  local schema = self:escape_identifier(self.config.schema)
  local ok, err = self:query(concat {
    "BEGIN;\n",
    "  DO $$\n",
    "  BEGIN\n",
    "    DROP SCHEMA IF EXISTS ", schema, " CASCADE;\n",
    "    CREATE SCHEMA IF NOT EXISTS ", schema, " AUTHORIZATION CURRENT_USER;\n",
    "    GRANT ALL ON SCHEMA ", schema ," TO CURRENT_USER;\n",
    "  EXCEPTION WHEN insufficient_privilege THEN\n", drop_tables,
    "  END;\n",
    "  $$;\n",
    "    SET SCHEMA ",  self:escape_literal(self.config.schema), ";\n",
    "COMMIT;",  })

  if not ok then
    return nil, err
  end

  return true
end


local setkeepalive


local function reconnect(config)
  local phase = get_phase()
  if phase == "init" or phase == "init_worker" then
    config.socket_type = "luasocket"

  else
    config.socket_type = "nginx"
  end

  local connection = pgmoon.new(config)

  connection.convert_null = true
  connection.NULL         = null

  if config.timeout then
    connection:settimeout(config.timeout)
  end

  local ok, err = connection:connect()
  if not ok then
    return nil, err
  end

  if config.schema == "" then
    local res = connection:query("SELECT CURRENT_SCHEMA AS schema")
    if res and res[1] and res[1].schema and res[1].schema ~= null then
      config.schema = res[1].schema
    else
      config.schema = "public"
    end
  end

  if connection.sock:getreusedtimes() == 0 then
    ok, err = connection:query(concat {
      "SET SCHEMA ",    connection:escape_literal(config.schema), ";\n",
      "SET TIME ZONE ", connection:escape_literal("UTC"), ";",
    })
    if not ok then
      setkeepalive(connection, config.keepalive_timeout)
      return nil, err
    end
  end

  return connection
end


local function connect(config)
  return kong.vault.try(reconnect, config)
end


setkeepalive = function(connection, keepalive_timeout)
  if not connection or not connection.sock then
    return true
  end

  if connection.sock_type == "luasocket" then
    local _, err = connection:disconnect()
    if err then
      return nil, err
    end

  else
    local _, err = connection:keepalive(keepalive_timeout)
    if err then
      return nil, err
    end
  end

  return true
end


local _mt = {
  reset = reset_schema
}


_mt.__index = _mt


function _mt:get_stored_connection(operation)
  local conn = self.super.get_stored_connection(self, operation)
  if conn and conn.sock then
    return conn
  end
end

function _mt:get_keepalive_timeout(operation)
  if self.config_ro and operation == 'read' then
    return self.config_ro.keepalive_timeout
  end

  return self.config.keepalive_timeout
end


function _mt:init()
  local res, err = self:query("SHOW server_version_num;")
  local ver = tonumber(res and res[1] and res[1].server_version_num)
  if not ver then
    return nil, "failed to retrieve PostgreSQL server_version_num: " .. (err or "")
  end

  local major = floor(ver / 10000)
  if major < 10 then
    self.major_version       = tonumber(fmt("%u.%u", major, floor(ver / 100 % 100)))
    self.major_minor_version = fmt("%u.%u.%u", major, floor(ver / 100 % 100), ver % 100)

  else
    self.major_version       = major
    self.major_minor_version = fmt("%u.%u", major, ver % 100)
  end

  return true
end


function _mt:init_worker(strategies)
  if ngx.worker.id() == 0 and #kong.configuration.admin_listeners > 0 then
    local table_names = get_names_of_tables_with_ttl(strategies)
    local ttl_escaped = self:escape_identifier("ttl")
    local expire_at_escaped = self:escape_identifier("expire_at")
    local cleanup_statements = {}
    local cleanup_statements_count = #table_names
    for i = 1, cleanup_statements_count do
      local table_name = table_names[i]
      local column_name = table_name == "cluster_events" and expire_at_escaped
                                                          or ttl_escaped
      local table_name_escaped = self:escape_identifier(table_name)

      cleanup_statements[i] = fmt([[
    WITH rows AS (
  SELECT ctid
    FROM %s
   WHERE %s < TO_TIMESTAMP(%s) AT TIME ZONE 'UTC'
ORDER BY %s LIMIT 50000 FOR UPDATE SKIP LOCKED)
  DELETE
    FROM %s
   WHERE ctid IN (TABLE rows);]], table_name_escaped, column_name, "%s", column_name, table_name_escaped)
    end

    return timer_every(self.config.ttl_cleanup_interval, function(premature)
      if premature then
        return
      end

      -- Fetch the end timestamp from database to avoid problems caused by the difference
      -- between nodes and database time.
      local cleanup_end_timestamp
      local ok, err = self:query("SELECT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC') AS NOW;")
      if not ok then
        log(WARN, "unable to fetch current timestamp from PostgreSQL database (",
                  err, ")")
        return
      end

      cleanup_end_timestamp = ok[1]["now"]

      for i, statement in ipairs(cleanup_statements) do
        local _tracing_cleanup_start_time = now()

        while true do -- batch delete looping
          -- using the server-side timestamp in the whole loop to prevent infinite loop
          local ok, err = self:query(fmt(statement, cleanup_end_timestamp))
          if not ok then
            if err then
              log(WARN, "unable to clean expired rows from table '",
                        table_names[i], "' on PostgreSQL database (",
                        err, ")")

            else
              log(WARN, "unable to clean expired rows from table '",
                        table_names[i], "' on PostgreSQL database")
            end
            break
          end

          if ok.affected_rows < 50000 then -- indicates that cleanup is done
            break
          end
        end

        local _tracing_cleanup_end_time = now()
        local time_elapsed =  _tracing_cleanup_end_time - _tracing_cleanup_start_time
        kong.log.trace(fmt("cleaning up expired rows from table '%s' took %.3f seconds",
                       table_names[i], time_elapsed))
      end
    end)
  end

  return true
end


function _mt:infos()
  local db_ver
  if self.major_minor_version then
    db_ver = match(self.major_minor_version, "^(%d+%.%d+)")
  end

  return {
    strategy    = "PostgreSQL",
    db_name     = self.config.database,
    db_schema   = self.config.schema,
    db_desc     = "database",
    db_ver      = db_ver or "unknown",
    db_readonly = self.config_ro ~= nil,
  }
end


function _mt:connect(operation)
  if operation ~= nil and operation ~= "read" and operation ~= "write" then
    error("operation must be 'read' or 'write', was: " .. tostring(operation), 2)
  end

  if not operation or not self.config_ro then
    operation = "write"
  end

  local conn = self:get_stored_connection(operation)
  if conn then
    return conn
  end

  local connection, err = connect(operation == "write" and
                                  self.config or self.config_ro)
  if not connection then
    return nil, err
  end

  self:store_connection(connection, operation)

  return connection
end


function _mt:connect_migrations()
  return self:connect("write")
end


function _mt:close()
  for operation in pairs(OPERATIONS) do
    local conn = self:get_stored_connection(operation)
    if conn then
      local _, err = conn:disconnect()

      self:store_connection(nil, operation)

      if err then
        return nil, err
      end
    end
  end

  return true
end


function _mt:setkeepalive()
  for operation in pairs(OPERATIONS) do
    local conn = self:get_stored_connection(operation)
    if conn then
      local keepalive_timeout = self:get_keepalive_timeout(operation)
      local _, err = setkeepalive(conn, keepalive_timeout)

      self:store_connection(nil, operation)

      if err then
        return nil, err
      end
    end
  end

  return true
end


function _mt:acquire_query_semaphore_resource(operation)
  local sem = self["sem_" .. operation]
  if not sem then
    return true
  end

  do
    local phase = get_phase()
    if phase == "init" or phase == "init_worker" then
      return true
    end
  end

  local ok, err = sem:wait(self.config.sem_timeout)
  if not ok then
    return nil, err
  end

  return true
end


function _mt:release_query_semaphore_resource(operation)
  local sem = self["sem_" .. operation]
  if not sem then
    return true
  end

  do
    local phase = get_phase()
    if phase == "init" or phase == "init_worker" then
      return true
    end
  end

  sem:post()
end


function _mt:query(sql, operation)
  if operation ~= nil and operation ~= "read" and operation ~= "write" then
    error("operation must be 'read' or 'write', was: " .. tostring(operation), 2)
  end

  local phase = get_phase()

  if not operation or
     not self.config_ro or
     (phase == "content" and ngx.ctx.KONG_PHASE == ADMIN_API_PHASE)
  then
    -- admin API requests skips the replica optimization
    -- to ensure all its results are always strongly consistent
    operation = "write"
  end

  local conn, is_new_conn
  local res, err, partial, num_queries

  local ok
  ok, err = self:acquire_query_semaphore_resource(operation)
  if not ok then
    return nil, "error acquiring query semaphore: " .. err
  end

  conn = self:get_stored_connection(operation)
  if not conn then
    local config = operation == "write" and self.config or self.config_ro

    conn, err = connect(config)
    if not conn then
      self:release_query_semaphore_resource(operation)
      return nil, err
    end
    is_new_conn = true
  end

  res, err, partial, num_queries = conn:query(sql)

  -- if err is string then either it is a SQL error
  -- or it is a socket error, here we abort connections
  -- that encounter errors instead of reusing them, for
  -- safety reason
  if err and type(err) == "string" then
    ngx.log(ngx.DEBUG, "SQL query throw error: ", err, ", close connection")
    local _, err = conn:disconnect()
    if err then
      -- We're at the end of the query - just logging if
      -- we cannot cleanup the connection
      ngx.log(ngx.ERR, "failed to disconnect: ", err)
    end
    self:store_connection(nil, operation)

  elseif is_new_conn then
    local keepalive_timeout = self:get_keepalive_timeout(operation)
    setkeepalive(conn, keepalive_timeout)
  end

  self:release_query_semaphore_resource(operation)

  if res then
    return res, nil, partial, num_queries or err
  end

  return nil, err, partial, num_queries
end


function _mt:iterate(sql)
  local res, err, partial, num_queries = self:query(sql, "read")
  if not res then
    local failed = false
    return function()
      if not failed then
        failed = true
        return false, err, partial, num_queries
      end
      -- return error only once to avoid infinite loop
      return nil
    end
  end

  if res == true then
    return iterator { true }
  end

  return iterator(res)
end


function _mt:truncate()
  local table_names, err = get_table_names(self, PROTECTED_TABLES)
  if not table_names then
    return nil, err
  end

  if #table_names == 0 then
    return true
  end

  local truncate_statement = concat {
    "TRUNCATE ", concat(table_names, ", "), " RESTART IDENTITY CASCADE;"
  }

  local ok, err = self:query(truncate_statement)
  if not ok then
    return nil, err
  end

  return true
end


function _mt:truncate_table(table_name)
  local truncate_statement = concat {
    "TRUNCATE ", self:escape_identifier(table_name), " RESTART IDENTITY CASCADE;"
  }

  local ok, err = self:query(truncate_statement)
  if not ok then
    return nil, err
  end

  return true
end


function _mt:setup_locks(_, _)
  logger.debug("creating 'locks' table if not existing...")

  local ok, err = self:query([[
BEGIN;
  CREATE TABLE IF NOT EXISTS locks (
    key    TEXT PRIMARY KEY,
    owner  TEXT,
    ttl    TIMESTAMP WITH TIME ZONE
  );
  CREATE INDEX IF NOT EXISTS locks_ttl_idx ON locks (ttl);
COMMIT;]])

  if not ok then
    return nil, err
  end

  logger.debug("successfully created 'locks' table")

  return true
end


function _mt:insert_lock(key, ttl, owner)
  local ttl_escaped = concat {
                        "TO_TIMESTAMP(",
                        self:escape_literal(tonumber(fmt("%.3f", now_updated() + ttl))),
                        ") AT TIME ZONE 'UTC'"
                      }

  local sql = concat { "BEGIN;\n",
                       "  DELETE FROM locks\n",
                       "        WHERE ttl < CURRENT_TIMESTAMP AT TIME ZONE 'UTC';\n",
                       "  INSERT INTO locks (key, owner, ttl)\n",
                       "       VALUES (", self:escape_literal(key),   ", ",
                                          self:escape_literal(owner), ", ",
                                          ttl_escaped, ")\n",
                       "  ON CONFLICT DO NOTHING;\n",
                       "COMMIT;"
  }

  local res, err, _, num_queries = self:query(sql)
  if not res then
    return nil, err
  end

  if num_queries ~= 4 then
    return nil, "unexpected result"
  end

  if res[3] and res[3].affected_rows == 1 then
    return true
  end

  return false
end


function _mt:read_lock(key)
  local sql = concat {
    "SELECT *\n",
    "  FROM locks\n",
    " WHERE key = ", self:escape_literal(key), "\n",
    "   AND ttl >= CURRENT_TIMESTAMP AT TIME ZONE 'UTC'\n",
    " LIMIT 1;"
  }

  local res, err = self:query(sql)
  if not res then
    return nil, err
  end

  return res[1] ~= nil
end


function _mt:remove_lock(key, owner)
  local sql = concat {
    "DELETE\n",
    "  FROM ", self:escape_identifier("locks"), "\n",
    " WHERE ", self:escape_identifier("key"), "   = ", self:escape_literal(key), "\n",
    "   AND ", self:escape_identifier("owner"), " = ", self:escape_literal(owner), ";"
  }

  local res, err = self:query(sql)
  if not res then
    return nil, err
  end

  return true
end


function _mt:schema_migrations()
  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  local table_names, err = get_table_names(self)
  if not table_names then
    return nil, err
  end

  local schema_meta_table_name = self:escape_identifier("schema_meta")
  local schema_meta_table_exists
  for _, table_name in ipairs(table_names) do
    if table_name == schema_meta_table_name then
      schema_meta_table_exists = true
      break
    end
  end

  if not schema_meta_table_exists then
    -- database, but no schema_meta: needs bootstrap
    return nil
  end

  local rows, err = self:query(concat({
    "SELECT *\n",
    "  FROM schema_meta\n",
    " WHERE key = ",  self:escape_literal("schema_meta"), ";"
  }), "read")

  if not rows then
    return nil, err
  end

  for _, row in ipairs(rows) do
    if row.pending == null then
      row.pending = nil
    end
  end

  -- no migrations: is bootstrapped but not migrated
  -- migrations: has some migrations
  return rows
end


function _mt:schema_bootstrap(default_locks_ttl)
  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  -- create schema if not exists

  logger.debug("creating '%s' schema if not existing...", self.config.schema)

  local schema = self:escape_identifier(self.config.schema)
  local ok, err = self:query(concat {
    "BEGIN;\n",
    "  DO $$\n",
    "  BEGIN\n",
    "    CREATE SCHEMA IF NOT EXISTS ", schema, " AUTHORIZATION CURRENT_USER;\n",
    "    GRANT ALL ON SCHEMA ", schema ," TO CURRENT_USER;\n",
    "  EXCEPTION WHEN insufficient_privilege THEN\n",
    "    -- Do nothing, perhaps the schema has been created already\n",
    "  END;\n",
    "  $$;\n",
    "  SET SCHEMA ",  self:escape_literal(self.config.schema), ";\n",
    "COMMIT;",
  })

  if not ok then
    return nil, err
  end

  logger.debug("successfully created '%s' schema", self.config.schema)

  -- create schema meta table if not exists

  logger.debug("creating 'schema_meta' table if not existing...")

  local res, err = self:query([[
    CREATE TABLE IF NOT EXISTS schema_meta (
      key            TEXT,
      subsystem      TEXT,
      last_executed  TEXT,
      executed       TEXT[],
      pending        TEXT[],

      PRIMARY KEY (key, subsystem)
    );]])

  if not res then
    return nil, err
  end

  logger.debug("successfully created 'schema_meta' table")

  local ok
  ok, err = self:setup_locks(default_locks_ttl, true)
  if not ok then
    return nil, err
  end

  return true
end


function _mt:schema_reset()
  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  return reset_schema(self)
end


function _mt:run_up_migration(name, up_sql)
  if type(name) ~= "string" then
    error("name must be a string", 2)
  end

  if type(up_sql) ~= "string" then
    error("up_sql must be a string", 2)
  end

  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  local sql = strip(up_sql)
  if sub(sql, -1) ~= ";" then
    sql = sql .. ";"
  end

  local sql = concat {
    "BEGIN;\n",
    sql, "\n",
    "COMMIT;\n",
  }

  local res, err = self:query(sql)
  if not res then
    self:query("ROLLBACK;")
    return nil, err
  end

  return true
end


function _mt:record_migration(subsystem, name, state)
  if type(subsystem) ~= "string" then
    error("subsystem must be a string", 2)
  end

  if type(name) ~= "string" then
    error("name must be a string", 2)
  end

  local conn = self:get_stored_connection()
  if not conn then
    error("no connection")
  end

  local key_escaped  = self:escape_literal("schema_meta")
  local subsystem_escaped = self:escape_literal(subsystem)
  local name_escaped = self:escape_literal(name)
  local name_array   = encode_array({ name })

  local sql
  if state == "executed" then
    sql = concat({
      "INSERT INTO schema_meta (key, subsystem, last_executed, executed)\n",
      "     VALUES (", key_escaped, ", ", subsystem_escaped, ", ", name_escaped, ", ", name_array, ")\n",
      "ON CONFLICT (key, subsystem) DO UPDATE\n",
      "        SET last_executed = EXCLUDED.last_executed,\n",
      "            executed = ARRAY_APPEND(COALESCE(schema_meta.executed, ARRAY[]::TEXT[]), ", name_escaped, ");",
    })

  elseif state == "pending" then
    sql = concat({
      "INSERT INTO schema_meta (key, subsystem, pending)\n",
      "     VALUES (", key_escaped, ", ", subsystem_escaped, ", ", name_array, ")\n",
      "ON CONFLICT (key, subsystem) DO UPDATE\n",
      "        SET pending = ARRAY_APPEND(schema_meta.pending, ", name_escaped, ");"
    })

  elseif state == "teardown" then
    sql = concat({
      "INSERT INTO schema_meta (key, subsystem, last_executed, executed)\n",
      "     VALUES (", key_escaped, ", ", subsystem_escaped, ", ", name_escaped, ", ", name_array, ")\n",
      "ON CONFLICT (key, subsystem) DO UPDATE\n",
      "        SET last_executed = EXCLUDED.last_executed,\n",
      "            executed = ARRAY_APPEND(COALESCE(schema_meta.executed, ARRAY[]::TEXT[]), ", name_escaped, "),\n",
      "            pending  = ARRAY_REMOVE(COALESCE(schema_meta.pending,  ARRAY[]::TEXT[]), ", name_escaped, ");",
    })

  else
    error("unknown 'state' argument: " .. tostring(state))
  end

  local res, err = self:query(sql)
  if not res then
    return nil, err
  end

  return true
end


local _M = {}


function _M.new(kong_config)
  local config = {
    application_name = "kong",
    host        = kong_config.pg_host,
    port        = kong_config.pg_port,
    timeout     = kong_config.pg_timeout,
    user        = kong_config.pg_user,
    password    = kong_config.pg_password,
    database    = kong_config.pg_database,
    schema      = kong_config.pg_schema or "",
    ssl         = kong_config.pg_ssl,
    ssl_verify  = kong_config.pg_ssl_verify,
    cafile      = kong_config.lua_ssl_trusted_certificate_combined,
    sem_max     = kong_config.pg_max_concurrent_queries or 0,
    sem_timeout = (kong_config.pg_semaphore_timeout or 60000) / 1000,
    pool_size   = kong_config.pg_pool_size,
    backlog     = kong_config.pg_backlog,

    --- not used directly by pgmoon, but used internally in connector to set the keepalive timeout
    keepalive_timeout = kong_config.pg_keepalive_timeout,
    --- non user-faced parameters
    ttl_cleanup_interval = kong_config._debug_pg_ttl_cleanup_interval or 300,
  }

  local refs = kong_config["$refs"]
  if refs then
    local user_ref = refs.pg_user
    local password_ref = refs.pg_password
    if user_ref or password_ref then
      config["$refs"] = {
        user = user_ref,
        password = password_ref,
      }
    end
  end

  local db = pgmoon.new(config)

  local sem
  if config.sem_max > 0 then
    local err
    sem, err = semaphore.new(config.sem_max)
    if not sem then
      ngx.log(ngx.CRIT, "failed creating the PostgreSQL connector semaphore: ",
                        err)
    end
  end

  local self = {
    config            = config,
    escape_identifier = db.escape_identifier,
    escape_literal    = db.escape_literal,
    sem_write         = sem,
  }

  if not ngx.IS_CLI and kong_config.pg_ro_host then
    ngx.log(ngx.DEBUG, "PostgreSQL connector readonly connection enabled")

    local ro_override = {
      application_name = "kong",
      host        = kong_config.pg_ro_host,
      port        = kong_config.pg_ro_port,
      timeout     = kong_config.pg_ro_timeout,
      user        = kong_config.pg_ro_user,
      password    = kong_config.pg_ro_password,
      database    = kong_config.pg_ro_database,
      schema      = kong_config.pg_ro_schema,
      ssl         = kong_config.pg_ro_ssl,
      ssl_verify  = kong_config.pg_ro_ssl_verify,
      cafile      = kong_config.lua_ssl_trusted_certificate_combined,
      sem_max     = kong_config.pg_ro_max_concurrent_queries,
      sem_timeout = kong_config.pg_ro_semaphore_timeout and
                    (kong_config.pg_ro_semaphore_timeout / 1000) or nil,
      pool_size   = kong_config.pg_ro_pool_size,
      backlog     = kong_config.pg_ro_backlog,

      --- not used directly by pgmoon, but used internally in connector to set the keepalive timeout
      keepalive_timeout = kong_config.pg_ro_keepalive_timeout,
    }

    if refs then
      local ro_user_ref = refs.pg_ro_user
      local ro_password_ref = refs.pg_ro_password
      if ro_user_ref or ro_password_ref then
        ro_override["$refs"] = {
          user = ro_user_ref,
          password = ro_password_ref,
        }
      end
    end

    local config_ro = table_merge(config, ro_override)

    local sem
    if config_ro.sem_max > 0 then
      local err
      sem, err = semaphore.new(config_ro.sem_max)
      if not sem then
        ngx.log(ngx.CRIT, "failed creating the PostgreSQL connector semaphore: ",
                          err)
      end
    end

    self.config_ro = config_ro
    self.sem_read = sem
  end

  return setmetatable(self, _mt)
end

-- for tests only
_mt._get_topologically_sorted_table_names = get_names_of_tables_with_ttl


return _M
