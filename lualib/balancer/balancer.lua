local ngx = ngx
local _M = {}
local ngx_balancer = require "ngx.balancer"
local balancer_config = require "balancer.config"
local cjson = require "cjson"
local backends = {}
local hosts = {}
local latest_sync_time = 0
local spawn = ngx.thread.spawn

local function is_server_up(backend_name, server_id)
    if backends[backend_name]["servers"][server_id].status == "up" then
        return true
    end
    return false
end

local function server_down(backend_name, server_id)
    if is_server_up(backend_name, server_id) then
        ngx.log(ngx.WARN, "server down: ", server_id)
        backends[backend_name]["servers"][server_id].status = "down"
    end
end

local function server_up(backend_name, server_id)
    if not is_server_up(backend_name, server_id) then
        ngx.log(ngx.WARN, "server up: ", server_id)
        backends[backend_name]["servers"][server_id].status = "up"
    end
end

local function tcp_check(server, config)
    local scok = ngx.socket.tcp()
    scok:settimeout(config.timeout * 1000)
    local ok, err = scok:connect(server.addr, server.port)
    scok:close()
    if not ok then
        return false
    end
    return true
end

local function http_check(server, config)
    local httpc = require("resty.http").new()
    httpc:set_timeout(config.timeout * 1000)
    local check_url = "http://" .. server.addr .. ":" .. server.port .. config.uri
    local res, err = httpc:request_uri(check_url, {
        method = "HEAD"
    })
    if not res then
        return false
    end
    if res.status ~= 200 then
        return false
    end
    return true
end

local function check_field(config)
    if config.type ~= "tcp" and config.type ~= "http" then
        config["type"] = "tcp"
    end

    if type(config.interval) ~= "number" then
        config["interval"] = 1
    elseif config.interval < 1 or config.interval > 60 then
        config["interval"] = 1
    end

    if type(config.timeout) ~= "number" then
        config["timeout"] = 1
    elseif config.timeout < 1 or config.timeout > 60 then
        config["timeout"] = 1
    end

    if type(config.success) ~= "number" then
        config["success"] = 1
    elseif config.success < 1 or config.success > 10 then
        config["success"] = 1
    end

    if type(config.fail) ~= "number" then
        config["fail"] = 1
    elseif config.fail < 1 or config.fail > 10 then
        config["fail"] = 1
    end

    if config.type == "http" and not config.uri then
        config["uri"] = "/"
    end

    return config
end

local function start_health_check(check_time, backend_name, server_id, server, config)
    config = check_field(config)
    local success_count = 0
    local fail_count = 0
    while true do
        ngx.log(ngx.DEBUG, "start check: ", server_id, " health_check: ", cjson.encode(config), " success_count: ",
            success_count, " fail_count: ", fail_count)
        if check_time ~= latest_sync_time or ngx.worker.exiting() then
            return
        end
        local ok = false
        if config.type == "tcp" then
            ok = tcp_check(server, config)
        elseif config.type == "http" then
            ok = http_check(server, config)
        end
        if not ok then
            fail_count = fail_count + 1
            if fail_count == config.fail then
                server_down(backend_name, server_id)
                fail_count = 0
            end
        else
            success_count = success_count + 1
            if success_count == config.success then
                server_up(backend_name, server_id)
                success_count = 0
            end
        end
        ngx.sleep(config.interval)
    end
end

local function sync_config()
    -- 判断配置是否更新过，如果没有更新过，则不需要同步配置
    if latest_sync_time > 0 then
        local latest_update_time = balancer_config.get_latest_update_time()
        if latest_update_time <= latest_sync_time then
            return
        end
    end

    -- 从共享内存中获取配置信息
    local config_data = balancer_config.get_config_data()
    if not config_data then
        ngx.log(ngx.WARN, "no config data found")
        return
    end

    local new_config = nil
    local ok = pcall(function()
        new_config = cjson.decode(config_data)
    end)
    if not ok or not new_config then
        ngx.log(ngx.ERR, "could not parse config data")
        return
    end

    if not new_config.backends or not new_config.hosts then
        ngx.log(ngx.ERR, "could not parse config data: ", config_data)
        return
    end

    latest_sync_time = ngx.time()
    ngx.log(ngx.INFO, "new sync config: ", latest_sync_time)

    local new_hosts = {}
    local new_backends = {}

    for _, backend in pairs(new_config.backends) do
        -- 判断是否是合法的端口号
        for _, server in pairs(backend.servers) do
            if type(server.port) ~= "number" then
                ngx.log(ngx.ERR, "invalid server port: ", server.port)
                return
            elseif server.port < 1 or server.port > 65535 then
                ngx.log(ngx.ERR, "invalid server port: ", server.port)
                return
            end
        end

        local servers = {}
        local new_backend = {}
        new_backend["servers"] = servers
        new_backend["best_server"] = nil
        new_backends[backend.backend_name] = new_backend

        for _, server in pairs(backend.servers) do
            local server_id = backend.backend_name .. "_" .. server.addr .. "_" .. server.port
            local weight = server.weight or 1
            servers[server_id] = {
                addr = server.addr,
                port = server.port,
                status = "up",
                current_weight = 0,
                effective_weight = weight
            }

            -- 定时检查后端服务器的健康状态
            if backend.health_check then
                if backend.health_check.enable == true then
                    spawn(start_health_check, latest_sync_time, backend.backend_name, server_id, server,
                        backend.health_check)
                end
            end
        end
    end
    backends = new_backends

    for _, host in pairs(new_config.hosts) do
        new_hosts[host.host] = host.backend_name
    end
    hosts = new_hosts

end

function _M.init_worker()
    -- 初始化启动配置
    balancer_config.init_worker()

    -- 每秒同步一次配置
    local ok, err = ngx.timer.every(1, sync_config)
    if not ok then
        ngx.log(ngx.ERR, "failed to create the timer: ", err)
        return
    end

end

local function get_backend(backend_name)
    local servers = nil
    local ok = pcall(function()
        servers = backends[backend_name]["servers"]
    end)
    if not ok then
        return nil
    end

    -- 使用加权轮询算法选择一个后端服务器
    local total_weight = 0
    local best_server = backends[backend_name].best_server
    for _, server in pairs(servers) do
        if server.status ~= "up" then
            goto continue
        end
        total_weight = total_weight + server.effective_weight
        server.current_weight = server.current_weight + server.effective_weight
        if not best_server or server.current_weight > best_server.current_weight then
            best_server = server
        end
        ::continue::
    end
    best_server.current_weight = best_server.current_weight - total_weight
    backends[backend_name].best_server = best_server
    return best_server
end

function _M.balance()
    local server = get_backend(hosts[ngx.var.host])
    if not server then
        ngx.log(ngx.ERR, "no backend server found")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
    local ok, err = ngx_balancer.set_current_peer(server.addr, server.port)
    if not ok then
        ngx.log(ngx.ERR, "failed to set the current peer: ", err)
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
end

return _M
