# Nginx 动态负载均衡

基于Openresty 的balancer 模块实现动态负载均衡、反向代理，可以根据Host 匹配upstream server

## 原理

- 配置一个默认`server{}` 和`upstream{}`
- 启动时执行`init_worker_by_lua`
- `init_worker_by_lua` 启动后获取配置存入共享内存`ngx.shared`，启动后每秒尝试获取最新的配置
- 默认情况下所有请求都会转发到 `upstream_balancer`
- `balancer_by_lua_block {}` 会根据`Host` 从`ngx.shared`中查找对应的后端

## 安装

```shell
# 拷贝文件到openresty的目录即可
cp -r conf openresty_path/
cp -r lualib openresty_path/

# 如果要开启http健康检查
git clone https://github.com/ledgetech/lua-resty-http.git
cp lua-resty-http/* openresty_path/lualib/resty/
```

## 配置更新

### 配置样例

```json
{
    "backends": [
        {
            "backend_name": "backend1",
            "health_check": {
                "enable": true,
                "type": "tcp",
                "interval": 3,
                "timeout": 2,
                "success": 2,
                "fail": 3
            },
            "servers": [
                {
                    "addr": "127.0.0.1",
                    "port": 10001
                }
            ]
        },
        {
            "backend_name": "backend2",
            "health_check": {
                "enable": true,
                "type": "http",
                "uri": "/ping",
                "interval": 3,
                "timeout": 2,
                "success": 2,
                "fail": 3
            },
            "servers": [
                {
                    "addr": "127.0.0.1",
                    "port": 10001,
                    "weight": 10
                },
                {
                    "addr": "127.0.0.1",
                    "port": 10002,
                    "weight": 1
                }
            ]
        }
    ],
    "hosts": [
        {
            "host": "www.test1.com",
            "backend_name": "backend1"
        },
        {
            "host": "www.test2.com",
            "backend_name": "backend2"
        }
    ]
}
```

### 持久化配置文件

启动时会根据 `init_worker_by_lua_block {}`  中的配置读取配置文件或者 redis

```lua
config_type = "file"
config_file = "./conf/config.json"
--config_type = "redis"
--redis_host = "127.0.0.1"
--redis_port = "6379"
--redis_key = "balancer"
--balancer.init_worker()
```

### 基于接口

设置 `x-save: 1` 则会持久化配置文件，不设置直接更新内存中的配置

```shell
curl -XPOST 'http://127.0.0.1:9001/config' \
-H 'x-save: 1' \
-H 'Content-Type: application/json' \
--data '{}'
```
