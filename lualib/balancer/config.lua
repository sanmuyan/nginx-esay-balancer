local ngx = ngx
local _M = {}
local redis = require "resty.redis"
local config_store = ngx.shared.config_store
local latest_update_time = 0

local function set_config(config)
    local success, err = config_store:set("config", config)
    if not success then
        ngx.log(ngx.ERR, "failed to set config in config_data: ", err)
    end
    latest_update_time = ngx.time()
    ngx.log(ngx.INFO, "new update config: ", latest_update_time)
    return success, err
end

local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect to redis: ", err)
    end
    return red
end

local function handle_redis_config()
    local red = redis_connect()
    if latest_update_time > 0 then
        local redis_update_time, err = red:get(redis_key .. ":update_time")
        redis_update_time = tonumber(redis_update_time)
        if not redis_update_time then
            return
        end

        if redis_update_time <= latest_update_time then
            return
        end
    end

    local config, err = red:get(redis_key .. ":config")
    if not config then
        return
    end
    set_config(config)
end

local function save_config(config_data)
    local red = redis_connect()
    local ok, err = red:set(redis_key .. ":config", config_data)
    if not ok then
        return ok, err
    end
    local ok, err = red:set(redis_key .. ":update_time", ngx.time())
    return ok, err
end

local function handle_api_config()
    ngx.req.read_body()
    local config = ngx.req.get_body_data()
    if not config then
        ngx.log(ngx.ERR, "no body data found")
        local status = ngx.HTTP_BAD_REQUEST
        return ngx.exit(status)
    end

    local headers = ngx.req.get_headers()
    if headers["x-save"] == "1" and redis_key then
        local ok, err = save_config(config)
        if not ok then
            ngx.log(ngx.ERR, "failed to save config to redis: ", err)
            return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    else
        local success, err = set_config(config)
        if not success then
            return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end
    ngx.say("success")
end

function _M.call()
    -- 处理API提交的配置
    handle_api_config()
end

function _M.init_worker()
    -- 处理数据库中的配置
    ngx.log(ngx.INFO, "redis_key: ", redis_key)
    if redis_key then
        local ok, err = ngx.timer.every(1, handle_redis_config)
        if not ok then
            ngx.log(ngx.ERR, "failed to create the timer: ", err)
            return
        end
    end
end

function _M.get_config_data()
    return config_store:get("config")
end

function _M.get_latest_update_time()
    return latest_update_time
end

return _M
