use lib 'lib';
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

my $pwd = cwd();

our $HttpConfig1 = qq{
    lua_shared_dict sync 5m;
    lua_shared_dict locks 1m;
    lua_package_path "$pwd/lib/?.lua;;";
    
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
};

our $HttpConfig2 = qq{
    lua_shared_dict sync 5m;
    lua_shared_dict locks 1m;
    lua_package_path "$pwd/lib/?.lua;;";
    
    init_worker_by_lua_block {
        local syncer = require "resty.sync"
    
        local sync, err = syncer.new(2, "sync")
        if not sync then
            ngx.log(ngx.ERR, "failed to create sync: ", err)
            return
        end
    
        local data, version = 0, 0
        local callback_task1 = function(mode)
            if mode == syncer.ACTION_DATA then
                data = data + 1
                return data  
             else
                version = version + 1
                return version
             end
        end
    
        local data, version = 0, 0
        local callback_task2 = function(mode)
            if mode == syncer.ACTION_DATA then
                data = data + 2
                return data  
             else
                version = version + 1
                return version
             end
        end
    
    
    
        local ok, err = sync.register(sync, callback_task1, "task1")
        if not ok then
            ngx.log(ngx.ERR, "failed to register task1: ", err)
            return
        end
    
        local ok, err = sync.register(sync, callback_task2, "task2")
        if not ok then
            ngx.log(ngx.ERR, "failed to register task2: ", err)
            return
        end
    
        sync.start(sync)
    
        SYNC = sync
    
    }
};

our $HttpConfig3 = qq{
    lua_shared_dict sync 5m;
    lua_shared_dict locks 1m;
    lua_package_path "$pwd/lib/?.lua;;";
    
    init_worker_by_lua_block {
        local syncer = require "resty.sync"
    
        local sync1, err = syncer.new(1, "sync")
        if not sync1 then
            ngx.log(ngx.ERR, "failed to create sync: ", err)
            return
        end
    
        local sync2, err = syncer.new(2, "sync")
        if not sync2 then
            ngx.log(ngx.ERR, "failed to create sync: ", err)
            return
        end
    
        local data, version = 0, 0
        local callback_task1 = function(mode)
            if mode == syncer.ACTION_DATA then
                data = data + 0.1
                return data  
             else
                version = version + 1
                return version
             end
        end
    
        local data, version = 0, 0
        local callback_task2 = function(mode)
            if mode == syncer.ACTION_DATA then
                data = data + 1
                return data  
             else
                version = version + 1
                return version
             end
        end
    
        local ok, err = sync1.register(sync1, callback_task1, "task1")
        if not ok then
            ngx.log(ngx.ERR, "failed to register task1: ", err)
            return
        end
    
        local ok, err = sync2.register(sync2, callback_task2, "task2")
        if not ok then
            ngx.log(ngx.ERR, "failed to register task2: ", err)
            return
        end
    
        sync1.start(sync1)
        sync2.start(sync2)
    
        SYNC1 = sync1
        SYNC2 = sync2
    
    }
};





master_on();
workers(4);
log_level("error");
no_long_string();
run_tests();

__DATA__

=== TEST 1: running normally

--- http_config eval: $::HttpConfig1

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


=== TEST 2: mutil tasks register on one sync
--- http_config eval: $::HttpConfig2
--- config
    location = /t {
        content_by_lua_block {
            local syncer = require "resty.sync"
            local sync = SYNC

            local task1_tag = "task1"
            local task2_tag = "task2"


            local data1, err = sync.get_data(sync, task1_tag)
            if not data1 then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task1: ", data1)

            local data2, err = sync.get_data(sync, task2_tag)
            if not data2 then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task2: ", data2)

            ngx.flush(true)


            ngx.sleep(0.1)

            local data, err = sync.get_data(sync, task1_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
            ngx.say("data from task1: ", data)

            local data, err = sync.get_data(sync, task2_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
            ngx.say("data from task2: ", data)

            ngx.flush(true)

            ngx.sleep(2)

            local data, err = sync.get_data(sync, task1_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task1: ", data)

            local data, err = sync.get_data(sync, task2_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task2: ", data)
            ngx.flush(true)

        }
    }

--- request
    GET /t

--- response_body
data from task1: 1
data from task2: 2
data from task1: 1
data from task2: 2
data from task1: 2
data from task2: 4


--- no_error_log
[error]


=== TEST 3: mutil tasks register on mutil sync
--- http_config eval: $::HttpConfig3

--- config
    location = /t {
        content_by_lua_block {
            local syncer = require "resty.sync"
            local sync1 = SYNC1
            local sync2 = SYNC2

            local task1_tag = "task1"
            local task2_tag = "task2"


            local data1, err = sync1.get_data(sync1, task1_tag)
            if not data1 then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task1: ", data1)

            local data2, err = sync2.get_data(sync2, task2_tag)
            if not data2 then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task2: ", data2)

            ngx.flush(true)


            ngx.sleep(0.1)

            local data, err = sync1.get_data(sync1, task1_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
            ngx.say("data from task1: ", data)

            local data, err = sync2.get_data(sync2, task2_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
            ngx.say("data from task2: ", data)

            ngx.flush(true)

            ngx.sleep(2)

            local data, err = sync1.get_data(sync1, task1_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task1: ", data)

            local data, err = sync2.get_data(sync2, task2_tag)
            if not data then
                ngx.log(ngx.ERR, "failed to get data: ", err)
                ngx.say("failed")
            end
                
            ngx.say("data from task2: ", data)
            ngx.flush(true)

        }
    }

--- request
    GET /t

--- response_body
data from task1: 0.1
data from task2: 1
data from task1: 0.1
data from task2: 1
data from task1: 0.3
data from task2: 2


--- no_error_log
[error]
