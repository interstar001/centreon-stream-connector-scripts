#!/usr/bin/lua
--------------------------------------------------------------------------------
-- Centreon Broker InfluxDB Connector
-- Tested with versions
-- 1.4.3, 1.7.4
--
-- References: 
-- https://docs.influxdata.com/influxdb/v1.4/write_protocols/line_protocol_tutorial/
-- https://docs.influxdata.com/influxdb/v1.4/guides/writing_data/
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Prerequisites:
-- You need an influxdb server
--      You can install one with docker and these commands:
--          docker pull influxdb
--          docker run -p 8086:8086 -p 8083:8083 -v $PWD:/var/lib/influxdb -d influxdb
-- You need to create a database
-- curl  http://<influxdb-server>:8086/query --data-urlencode "q=CREATE DATABASE mydb"
--
-- The Lua-socket and Lua-sec libraries are required by this script.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Access to the data:
-- curl -G 'http://<influxdb-server>:8086/query?pretty=true' --data-urlencode "db=mydb" --data-urlencode "q=SELECT * from Cpu"
--------------------------------------------------------------------------------

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")

--------------------------------------------------------------------------------
-- EventQueue class
--------------------------------------------------------------------------------

local EventQueue = {}
EventQueue.__index = EventQueue

--------------------------------------------------------------------------------
-- flush() method
-- Called when the max number of events or the max age are reached
--------------------------------------------------------------------------------

function EventQueue:flush()
    broker_log:info(3, "EventQueue:flush: Concatenating all the events as one string")
    --  we concatenate all the events
    local http_post_data = ""
    local http_result_body = {}
    for _, raw_event in ipairs(self.events) do
        http_post_data = http_post_data .. raw_event
    end
    broker_log:info(2, "EventQueue:flush: HTTP POST request \"" .. self.http_server_protocol .. "://" .. self.http_server_address .. ":" .. self.http_server_port .. "/write?db=" .. self.influx_database .. "\"")
    broker_log:info(3, "EventQueue:flush: HTTP POST data are: '" .. http_post_data .. "'")
    http.TIMEOUT = self.http_timeout
    local req
    if self.http_server_protocol == "http" then
        req = http
    else
        req = https
    end
    local hr_result, hr_code, hr_header, hr_s = req.request{
        url = self.http_server_protocol .. "://" .. self.http_server_address .. ":" .. self.http_server_port .. "/write?db=" .. self.influx_database .. "&u=" .. self.influx_username .. "&p=" .. self.influx_password,
        method = "POST",
        -- sink is where the request result's body will go
        sink = ltn12.sink.table(http_result_body),
        -- request body needs to be formatted as a LTN12 source
        source = ltn12.source.string(http_post_data),
        headers = {
            -- mandatory for POST request with body
            ["content-length"] = string.len(http_post_data)
        }
    }
    -- Handling the return code
    if hr_code == 204 then
        broker_log:info(2, "EventQueue:flush: HTTP POST request successful: return code is " .. hr_code)
        -- now that the data has been sent, we empty the events array
        self.events = {}
    else
        broker_log:error(1, "EventQueue:flush: HTTP POST request FAILED: return code is " .. hr_code)
        for i, v in ipairs(http_result_body) do
            broker_log:error(1, "EventQueue:flush: HTTP POST request FAILED: message line " .. i ..  " is \"" .. v .. "\"")
        end
    end
    -- and update the timestamp
    self.__internal_ts_last_flush = os.time()
end

--------------------------------------------------------------------------------
-- EventQueue:add method
-- @param e An event
--------------------------------------------------------------------------------

function EventQueue:add(e)
    broker_log:info(3, "EventQueue:add: " .. broker.json_encode(e))
    -- let's get and verify we have perfdata
    local perfdata, perfdata_err = broker.parse_perfdata(e.perfdata)
    if perfdata_err then
        broker_log:info(3, "EventQueue:add: No metric: " .. perfdata_err)
        return true
    end
    -- retrieve objects names instead of IDs
    local host_name = broker_cache:get_hostname(e.host_id)
    local service_description
    if e.service_id then
        service_description = broker_cache:get_service_description(e.host_id, e.service_id)
    else
        service_description = "host-latency"
    end
    -- what if we could not get them from cache
    if not host_name then
        broker_log:warning(1, "EventQueue:add: host_name for id " .. e.host_id .. " not found. Restarting centengine should fix this.")
        host_name = e.host_id
    end
    if not service_description then
        broker_log:warning(1, "EventQueue:add: service_description for id " .. e.host_id .. "." .. e.service_id .. " not found. Restarting centengine should fix this.")
        service_description = e.service_id
    end
    -- message format : <measurement>[,<tag-key>=<tag-value>...] <field-key>=<field-value>[,<field2-key>=<field2-value>...] [unix-nano-timestamp]
    -- consider space in service_description as a separator for an item tag
    local item = ""
    if string.find(service_description, " ") then
        item = ",item=" .. string.gsub(service_description, ".* ", "")
        service_description = string.gsub(service_description, " .*", "")
    end
    -- define messages from perfata, transforming instance names to inst tags, which leads to one message per instance
    local instances = {}
    for m,v in pairs(perfdata) do
        local inst = string.match(m, "(.*)#.*")
        if not inst then
            inst = ""
        else
            inst = ",inst=" .. inst
        end
        if not instances[inst] then
            instances[inst] = self.measurement .. service_description .. ",host=" .. host_name .. item .. inst .. " "
        end
        instances[inst] = instances[inst] .. string.gsub(m, ".*#", "") .. "=" .. v .. ","
    end
    -- compute final messages to push
    for _,v in pairs(instances) do
        self.events[#self.events + 1] = v:sub(1, -2) .. " " .. e.last_check .. "000000000" .. "\n"
        broker_log:info(3, "EventQueue:add: adding " .. self.events[#self.events]:sub(1, -2))
    end
    -- then we check whether it is time to send the events to the receiver and flush
    if #self.events >= self.max_buffer_size then
        broker_log:info(2, "EventQueue:add: flushing because buffer size reached " .. self.max_buffer_size .. " elements.")
        self:flush()
        return true
    elseif os.time() - self.__internal_ts_last_flush >= self.max_buffer_age then
        broker_log:info(2, "EventQueue:add: flushing " .. #self.events .. " elements because buffer age reached " .. (os.time() - self.__internal_ts_last_flush) .. "s and max age is " .. self.max_buffer_age .. "s.")
        self:flush()
        return true
    else
        return false
    end
end

--------------------------------------------------------------------------------
-- Constructor
-- @param conf The table given by the init() function and returned from the GUI
-- @return the new EventQueue
--------------------------------------------------------------------------------

function EventQueue.new(conf)
    local retval = {
        measurement                 = "",
        http_server_address         = "",
        http_server_port            = 8086,
        http_server_protocol        = "https",
        http_timeout                = 5,
        influx_database             = "mydb",
        influx_username             = "",
        influx_password             = "",
        max_buffer_size             = 5000,
        max_buffer_age              = 30,
        log_level                   = 0 -- already proceeded in init function
    }
    for i,v in pairs(conf) do
        if retval[i] then
            retval[i] = v
            if i == "influx_password" then
                v = string.gsub(v, ".", "*")
            end
            broker_log:info(1, "EventQueue.new: getting parameter " .. i .. " => " .. v)
            if i == "measurement" then
                retval[i] = retval[i] .. ",service="
            end
        else
            broker_log:warning(1, "EventQueue.new: ignoring parameter " .. i .. " => " .. v)
        end
    end
    retval.__internal_ts_last_flush = os.time()
    retval.events = {},
    setmetatable(retval, EventQueue)
    -- Internal data initialization
    broker_log:info(2, "EventQueue.new: setting the internal timestamp to " .. retval.__internal_ts_last_flush)
    return retval
end

--------------------------------------------------------------------------------
-- Required functions for Broker StreamConnector
--------------------------------------------------------------------------------

local queue

-- Fonction init()
function init(conf)
    local log_level = 3
    for i,v in pairs(conf) do
        if i == "log_level" then
            log_level = v
        end
    end
    broker_log:set_parameters(log_level, "/var/log/centreon-broker/stream-connector-influxdb-neb.log")
    broker_log:info(2, "init: Beginning init() function")
    queue = EventQueue.new(conf)
    broker_log:info(2, "init: Ending init() function, Event queue created")
end

-- Fonction write()
function write(e)
    broker_log:info(3, "write: Beginning write() function")
    queue:add(e)
    broker_log:info(3, "write: Ending write() function")
    return true
end

-- Fonction filter()
-- return true if you want to handle this type of event (category, element) ; here category NEB and element Host or Service
-- return false otherwise
function filter(category, element)
    return category == 1 and (element == 14 or element == 24)
end
