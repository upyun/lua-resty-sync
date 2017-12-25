-- Copyright (C) UPYUN, Inc.


local lock = require "resty.lock"

local ngx             = ngx
local ngx_lua_ver     = ngx.config.ngx_lua_version
local ngx_timer_at    = ngx.timer.at
local ngx_timer_every = ngx.timer.every
local ngx_time        = ngx.time
local ngx_null        = ngx.null
local ngx_log         = ngx.log
local ngx_shared      = ngx.shared
local ngx_now         = ngx.now
local worker_id       = ngx.worker.id
local worker_pid      = ngx.worker.pid
local get_phase       = ngx.get_phase
local WARN            = ngx.WARN
local NOTICE          = ngx.NOTICE

local table_insert    = table.insert
local str_format      = string.format
local os_time         = os.time
local type            = type
local setmetatable    = setmetatable

local UNINITIALIZED = 0
local INITIALIZED   = 1
local TIMER_RUNNING = 2

local INIT_WORKER = "init_worker"


local _M = {
    _VERSION = "0.06",
    state    = UNINITIALIZED,

    ACTION_DATA    = 0,
    ACTION_VERSION = 1,
}

local mt = { __index = _M }

local STATE_MAP = {
    [UNINITIALIZED] = "uninitalized",
    [INITIALIZED]   = "no task",
    [TIMER_RUNNING] = "timer is running",
}


local function is_tab(obj) return type(obj) == "table" end
local function is_null(obj) return obj == ngx_null or obj == nil end
local function is_num(obj) return type(obj) == "number" end
local function is_str(obj) return type(obj) == "string" end
local function is_func(obj) return type(obj) == "function" end


local function warn(...)
    ngx_log(WARN, "sync: ", ...)
end


local function notice(...)
    ngx_log(NOTICE, "sync: ", ...)
end


local function get_lock(key)
    local phase   = get_phase()
    local timeout = (phase == INIT_WORKER and 0 or nil)

    -- ngx.sleep API(called by lock:lock) is disabled in phase init_worker, so
    -- just set wait timeout to 0(return immediately)
    local lock = lock:new("locks", {timeout=timeout})

    local elapsed, err = lock:lock(key)

    if not elapsed then
        warn("failed to acquire lock: ", key, err)
        return
    end

    return lock
end


local function release_lock(lock)
    local ok, err = lock:unlock()
    if not ok then
        warn("failed to unlock: ", err)
    end
end


local function set_to_shm(self, task, data, version, last_modified)
    local shm = ngx_shared[self.shm]

    local succ, err = shm:set(task.shm_time_key, last_modified)
    if not succ then
        return nil, "failed to set last_modified to shm "
                    .. self.shm .. ": " .. err
    end

    succ, err = shm:set(task.shm_data_key, data)
    if not succ then
        return nil, "failed to set data to shm " .. self.shm .. ": " .. err
    end

    succ, err = shm:set(task.shm_version_key, version)
    if not succ then
        return nil, "failed to set version to shm " .. self.shm .. ": " .. err
    end

    return true
end


local function work(self, task)
    local version, err = task.callback(_M.ACTION_VERSION)

    if is_null(version) then
        warn("failed to get version of ", task.tag, ": ", err)
        return
    end

    if version ~= task.version then
        local data, err = task.callback(_M.ACTION_DATA)
        if is_null(data) then
            warn("failed to get data of ", task.tag, ": ", err)
            return
        end
        local now = ngx_time()

        local ok, err = set_to_shm(self, task, data, version, now)
        if not ok then
            warn(err)
            return
        end

        task.version = version
        task.data = data
        task.last_modified = now

        notice("update successfully for task ", task.tag, ", version: ",
               version, ", last_modified: ", now)
    end
end


local function run(self)
    notice("sync timer running, interval: ", self.interval,
           " total tasks: ", #self.tasks, ", owner worker id: ", worker_id(),
           ", owner worker pid: ", worker_pid())

    local tasks = self.tasks
    for _, v in ipairs(tasks) do
        work(self, v)
    end
end


function _M.get_version(self, tag)
    if self.state ~= TIMER_RUNNING then
        return nil, STATE_MAP[self.state]
    end

    if not is_str(tag) or not self.tags[tag] then
        return nil, "invalid tag"
    end

    local id = self.tags[tag]
    local task = self.tasks[id]

    local shm = ngx_shared[self.shm]
    local shm_version, err = shm:get(task.shm_version_key)
    if err then
        return nil, err
    end

    if is_null(shm_version) then
        return nil, "no version"
    end

    if shm_version == task.version then
        return task.version
    end

    -- update data 
    local data, err = shm:get(task.shm_data_key)
    if err then
        return nil, err
    end
    if is_null(data) then
        return nil, "no data"
    end

    task.version = shm_version
    task.data = data

    return task.version
end


function _M.get_data(self, tag)
    if self.state ~= TIMER_RUNNING then
        return nil, STATE_MAP[self.state]
    end

    if not is_str(tag) or not self.tags[tag] then
        return nil, "invalid tag"
    end

    local id = self.tags[tag]
    local task = self.tasks[id]

    local shm = ngx_shared[self.shm]
    local shm_version, err = shm:get(task.shm_version_key)
    if err then
        return nil, err
    end

    if is_null(shm_version) then
        return nil, "no version"
    end

    -- equal version, no need fetch from shdict
    if shm_version == task.version then
        return task.data
    end

    local data, err = shm:get(task.shm_data_key)
    if err then
        return nil, err
    end

    if is_null(data) then
        return nil, "no data"
    end

    task.version = shm_version
    task.data = data

    return data

end


function _M.get_last_modified_time(self, tag)
    if self.state ~= TIMER_RUNNING then
        return nil, STATE_MAP[self.state]
    end

    if not is_str(tag) or not self.tags[tag] then
        return nil, "invalid tag: " .. tag
    end

    local id = self.tags[tag]

    if self.owner == true then
        if is_null(self.tasks[id].last_modified) then
            return nil, "no data"
        end

        return self.tasks[id].last_modified
    end

    local shm = ngx_shared[self.shm]
    local time, err = shm:get(self.tasks[id].shm_time_key)
    if err then
        return nil, err
    end

    if is_null(time) then
        return nil, "no data"
    end

    return time
end


function _M.start(self)
    if self.state ~= INITIALIZED then
        return nil, STATE_MAP[self.state]
    end

    if #self.tasks == 0 then
        return nil, "no task registered"
    end

    self.state = TIMER_RUNNING

    local LOCK_KEY = self.LOCK_KEY
    local LOCK_TIMER_KEY = self.LOCK_TIMER_KEY
    local id = worker_id()
    if not is_num(id) then
        -- cache loader process and privileged_agent also will run
        -- the "init_worker_by_lua*" hooks, so let's just reject them.
        return true
    end

    local function wrapper_event(premature)
        if premature then
            return
        end

        run(self)

        local shm = ngx_shared[self.shm]
        local ok, err = shm:set(LOCK_TIMER_KEY, id, self.interval + 10)
        if not ok then
            warn("failed to set shm ", self.shm, ": ", err)
        end

        if ngx_lua_ver < 10009 then
            local interval = self.interval
            local ok, err = ngx_timer_at(interval, wrapper_event)
            if not ok then
                warn("failed to create timer: ", err)
            end
        end
    end

    local shm = ngx.shared[self.shm]
    local val = shm:get(LOCK_TIMER_KEY)

    if val and val ~= id then
        -- timer existed
        return true
    end

    -- timer can be created in these cases:
    -- * Nginx start
    -- * Nginx reload
    -- * the timer owner worker crash

    local lock = get_lock(LOCK_KEY)
    if not lock then
        return
    end

    val = shm:get(LOCK_TIMER_KEY)

    if val and val ~= id then
        if lock then 
            release_lock(lock) 
        end

        return true
    end

    self.owner = true

    run(self)

    local timer_method
    -- ngx.timer.every was first introduced in the v0.10.9 release.
    if ngx_lua_ver < 10009 then
        timer_method = ngx_timer_at
    else
        timer_method = ngx_timer_every
    end

    local ok, err = timer_method(self.interval, wrapper_event)
    if not ok then
        warn("failed to create timer: ", err)
        release_lock(lock)
        return nil, err
    end

    ok, err = shm:set(LOCK_TIMER_KEY, id, self.interval + 10)
    if not ok then
        warn("failed to set shm ",self.shm, ": ", err)
    end

    release_lock(lock)

    return true
end


-- register one task for the specific task group
function _M.register(self, callback, tag)
    if self.state ~= INITIALIZED then
        return nil, STATE_MAP[self.state]
    end

    if not is_func(callback) then
        return nil, "type of callback is function but seen " .. type(callback)
    end

    if not is_str(tag) then
        return nil, "type of tag is string but seen " .. type(tag)
    end

    if self.tags[tag] then
        return nil, "tag is existed"
    end

    local id = #self.tasks + 1
    self.tags[tag] = id

    table_insert(self.tasks, {
        tag             = tag,
        callback        = callback,
        shm_data_key    = "_data_" .. tag,
        shm_version_key = "_version_" .. tag,
        shm_time_key    = "_time_" .. tag,
    })

    notice("register a task successfully, tag: ", tag)

    return true
end


-- construct a task group
function _M.new(interval, shm)
    if not is_num(interval) then
        return nil, "type of interval is number but get " .. type(interval)
    end

    if not is_str(shm) then
        return nil, "type of shm name is string but get " .. type(shm)
    end

    if not ngx_shared[shm] then
        return nil, "no such shm: " .. shm
    end

    if interval <= 0 then
        return nil, "interval must be larger than 0"
    end

    local now = os_time()

    local instance = {
        interval       = interval,
        owner          = false,
        shm            = shm,
        state          = INITIALIZED,
        tags           = {},
        tasks          = {},

        -- key of each instance mustn't be duplicate
        LOCK_KEY       = str_format("sync_%d", now),
        LOCK_TIMER_KEY = str_format("sync_timer_%d", now)
    }

    return setmetatable(instance, mt)
end


return _M
