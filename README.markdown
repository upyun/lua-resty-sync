Name
====

lua-resty-sync - synchronizing data based on version changes

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Status](#status)
* [Methods](#methods)
    + [new](#new)
    + [register](#register)
    + [start](#start)
    + [get_version](#get_version)
    + [get_data](#get_data)
    + [get_last_modified_time](#get_last_modified_time)
* [TODO](#todo)
* [Author](#author)
* [Copyright and License](#copyright-and-license)

Synopsis
=======

```nginx

http {
    lua_shared_dict sync 5m;
    lua_shared_dict locks 1m;

    init_worker_by_lua_block {
        local sync = require "resty.sync"

        local syncer, err = sync.new(5, "sync")
        if not syncer then
            ngx.log(ngx.WARN, "failed to create sync object: ", err)
            return
        end

        local callback = function(mode)
            if mode == sync.ACTION_DATA then
                -- GET DATA
                return "data " .. math.random(100) -- just some fake data
            else
                -- GET VERSION
                return "version " .. math.random(100)
            end
        end

        -- register some tasks
        syncer:register(callback, "ex1")

        -- start to run
        syncer:start()

        -- save it
        SYNCER = syncer
    }

    server {
        server_name _;
        listen *:9080;

        location = /t {
            content_by_lua_block {
                local sync = require "resty.sync"

                local syncer = SYNCER

                local version, err = syncer:get_version("ex1")
                if not version then
                    ngx.log(ngx.WARN, "failed to fetch version: ", err)
                    return
                end

                local data, err = syncer:get_data("ex1")

                if not data then
                    ngx.log(ngx.WARN, "failed to fetch data: ", err)
                    return
                end

                ngx.say("task ex1, data: ", data, " and version: ", version)

                ngx.sleep(5)

                -- after 5s
                local version2, err = syncer:get_version("ex1")
                if not version2 then
                	ngx.log(ngx.WARN, "failed to fetch version: ", err)
                	return
                end

                local data2, err = syncer:get_data("ex1")

                if not data2 then
                	ngx.log(ngx.WARN, "failed to fetch data: ", err)
                	return
                end

                ngx.say("after 5s, task ex1, data: ", data2, " and version: ", version2)
            }
        }
    }
}
```

Description
===========

This lua-resty library help you to synchronize data(from redis, mysql,
memcached and so on) based on the version changes.  

It will check the freshness by comparing the version cached by itself(stored in shared memory) and the one from your external suits,
 data will be updated when the cached one is stale or for the first time.
See the [Synopsis](#synopsis) and [Methods](#methods) for learning how to use this library.

Note this lua module relies on [lua-resty-lock](https://github.com/openresty/lua-resty-lock).


Status
======

Probably production ready in most cases, though not yet proven in the wild.  
Please check the issues list and let me know if you have any problems /
questions.


Methods
=======

new
---

**syntax:** *local syncer, err = sync.new(interval, shm)*  

**phase:** *init_worker*  


Create and return an instance of the sync.

The first argument, `interval`, indicates the interval of two successive
operations(in seconds), which shall be greater than 0.  
The second argument `shm`, holds a Lua string, represents a shared
memory.

In the case of failure, `nil` and a Lua string described the corresponding error will be given.

register
-------

**syntax:** *local ok, err = syncer:register(callback, tag)*  

**phase:** *init_worker*  


Register a task to the instance `syncer` which created by [new](#new).

The first argument `callback`, can be any Lua function which will be invoked later in a background "light thread".  
The callback function not only used for capturing data, but also used for fetching version.  

Only one argument `mode` can be passed to this function and the value always is:

* sync.ACTION_DATA - capturing data this time.
* sync.ACTION_VERSION - fetching version this time.


The second argument `tag` is a Lua string which is used for distinguishing different tasks,  
so it can't be duplicate with one task registered previously.

In the case of failure, `nil` and a Lua string described the corresponding error will be given.

start
=====

**syntax:** *local ok, err = syncer:start()*

**phase:** *init_worker*

Let the instance `syncer` starts to work. Note there will be only one timer created among all workers.  
The uniqueness is kept throughout your service's lifetime even the timer owner worker is crash or nginx reload happens.  

Callback in this instance will be run orderly(accroding the order of register).

In the case of failure, `nil` and a Lua string described the corresponding error will be given.

get_version
-----------

**syntax:** *local version, err = syncer:get_version(tag)*

**phase**: *set_by_lua, rewrite_by_lua, access_by_lua, content_by_lua, header_filter_by_lua, body_filter_by_lua, log_by_lua,*  
*ngx.timer.\*, balancer_by_lua, ssl_certificate_by_lua, ssl_session_fetch_by_lua, ssl_session_store_by_lua*

Get the current version of one task(specified by `tag`).

In the case of failure, `nil` and a Lua string described the corresponding error will be given.  

In particually, `nil` and `"no data"` will be given when there is no data.

get_data
--------

**syntax:** *local data, err = syncer:get_data(tag)*

**phase**: *set_by_lua, rewrite_by_lua, access_by_lua, content_by_lua, header_filter_by_lua, body_filter_by_lua, log_by_lua,*  
*ngx.timer.\*, balancer_by_lua, ssl_certificate_by_lua, ssl_session_fetch_by_lua, ssl_session_store_by_lua*

Get the current data of one task(specified by `tag`).

In the case of failure, `nil` and a Lua string described the corresponding error will be given.  

In particually, `nil` and `"no data"` will be given when there is no data.

get_last_modified_time
----------------------

**syntax:** *local timestamp, err = syncer:get_last_modified_time(tag)*

**phase**: *set_by_lua, rewrite_by_lua, access_by_lua, content_by_lua, header_filter_by_lua, body_filter_by_lua, log_by_lua,*  
    *ngx.timer.\*, balancer_by_lua, ssl_certificate_by_lua, ssl_session_fetch_by_lua, ssl_session_store_by_lua*

Get the last update time(unix timestamp) of one task(specified by `tag`).

In the case of failure, `nil` and a Lua string described the corresponding error will be given.  

In particually, `nil` and `"no data"` will be given when there is no data.


TODO
====

* Do the updates cocurrently in one sync instance.


Author
======

Alex Zhang(张超) zchao1995@gmail.com, UPYUN Inc.


Copyright and License
=====================

The bundle itself is licensed under the 2-clause BSD license.

Copyright (c) 2017, UPYUN(又拍云) Inc.

This module is licensed under the terms of the BSD license.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this
list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.


THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
