use lib 'lib';
use Test::Nginx::Socket 'no_plan';

run_tests();

__DATA__

=== TEST 1: running normally

--- http_config

lua_shared_dict sync 5m;
lua_shared_dict locks 1m;

init_worker_by_lua_block {
    local sync = require "resty.sync"

    local syncer, err = sync.new(2, "sync")
    if not syncer then
        ngx.log(ngx.ERR, "failed to create sync object: ", err)
        return
    end

    local count = 0

    local callback = function(mode)
        count = count + 1
        if mode == sync.ACTION_DATA then
            -- GET DATA
            return "data " .. count
        else
            return "version " .. count
        end
    end

    syncer:register(callback, "ex1")

    syncer:start()

    SYNCER = syncer
}

--- config

location = /t {
    content_by_lua_block {
        local sync = require "resty.sync"

        local syncer = SYNCER
        local version, err = syncer:get_version("ex1")
        if not version then
            ngx.log(ngx.ERR, "failed to fetch version: ", err)
            ngx.say("failed")
            return
        end

        local data, err = syncer:get_data("ex1")

        if not data then
            ngx.log(ngx.ERR, "failed to fetch data: ", err)
            ngx.say("failed")
            return
        end

        ngx.say("first time, task ex1, data: ", data, " and version: ", version)
        ngx.log(ngx.WARN, data, " ", version)

        ngx.sleep(2.1)

        -- after 1s
        local version2, err = syncer:get_version("ex1")
        if not version2 then
            ngx.log(ngx.ERR, "failed to fetch version: ", err)
        return
        end

        local data2, err = syncer:get_data("ex1")

        if not data2 then
            ngx.log(ngx.ERR, "failed to fetch data: ", err)
            ngx.say("failed")
            return
        end

        ngx.say("second time, task ex1, data: ", data2, " and version: ", version2)

        ngx.sleep(0.1)
        local version3, err = syncer:get_version("ex1")
        if not version3 then
            ngx.log(ngx.ERR, "failed to fetch version: ", err)
            return
        end

        local data3, err = syncer:get_data("ex1")

        if not data3 then
            ngx.log(ngx.ERR, "failed to fetch data: ", err)
            ngx.say("failed")
            return
        end

        ngx.say("third time, task ex1, data: ", data3, " and version: ", version3)
    }
}

--- request
GET /t

--- response_body
first time, task ex1, data: data 2 and version: version 1
second time, task ex1, data: data 4 and version: version 3
third time, task ex1, data: data 4 and version: version 3

--- no_error_log
[error]
