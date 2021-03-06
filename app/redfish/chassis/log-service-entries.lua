--[[
   Copyright 2018 American Megatrends Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
--]]

-- [See "redfish-handler.lua"](/redfish-handler.html)
local RedfishHandler = require("redfish-handler")
-- [See "constants.lua"](/constants.html)
local CONSTANTS = require("constants")
-- [See "config.lua"](/config.html)
local CONFIG = require("config")
-- [See "utils.lua"](/utils.html)
local utils = require("utils")
-- [See "turbo library"](http://turbolua.org)
local turbo = require("turbo")
-- [See "underscore.lua"](https://mirven.github.io/underscore.lua/)
local _ = require("underscore")

local LogServiceEntriesHandler = class("LogServiceEntriesHandler", RedfishHandler)

local yield = coroutine.yield

-- Set the path names for chassis log entry OEM extensions
local collection_oem_path = "chassis.chassis-logentry-collection"
LogServiceEntriesHandler:set_oem_collection_path(collection_oem_path)

-- Load OEM log entry extensions, OEM directory structure follows from server.lua
-- After loading OEM extensions, the OEM tables are re-organzied to facilitate their use with Redis

local oem_properties = {}
local oem_formatting = {}
local oem_odata_type = {}

local oem_dirs = utils.get_oem_dirs()

for oi, on in ipairs(oem_dirs) do

	local oem_exists, oem_log_entry =  pcall(require, on .. ".log-entry")
	local oem_name_exists, oem_info =  pcall(require, on .. ".info")
	local OEM = oem_name_exists and oem_info.name or string.sub(on, 5)

	if oem_exists then
		-- OEM extensions are nested tables of the form: Log_Entry[log_type][property_name] = property_type
		-- Here we re-organize those into one table, indexed by log type, of arrays of properties with name, type, and oem fields
		for log_type, log_props in pairs(oem_log_entry.properties) do
			oem_properties[log_type] = oem_properties[log_type] or {}	
			for prop_name, prop_type in pairs(log_props) do
				property = {
					Name = prop_name, 
					Type = prop_type, 
					OEM = OEM
				}
				table.insert(oem_properties[log_type], property)
			end
		end
		oem_formatting[OEM] = oem_log_entry.formatting or {}
		oem_odata_type[OEM] = oem_log_entry.odata_type or ""
	end

end

-- ### GET request handler for Chassis/LogServices/Entries
function LogServiceEntriesHandler:get(_chassis_id, _log_id, id)

	local response = {}

	-- Create the GET response for Log Entries collection or instance, based on what 'id' was given.
	if id == nil then
		self:get_collection(response)
	else
		self:get_instance(response)
	end

	-- After the response is created, we register it with the handler and then output it to the client.
	self:set_response(response)

	-- GET requests must respond with the 'Allow' header specifying what methods are available for the given URL
	self:set_allow_header("GET")

	self:output()
end

-- #### GET handler for Log Service Entries collection
function LogServiceEntriesHandler:get_collection(response)
	-- Before proceeding with the handler, we'll make sure the collection request is valid
	local collection_exists = self:parent_exists()
	self:assertTrue_404(collection_exists)

	-- Set up the local space: get a connection with Redis DB, gather url segment, establish redis prefix, and set scope
	local redis = self:get_db()

	local collection, instance, secondary_collection, secondary_instance, inner_collection = 
		self.url_segments[1], self.url_segments[2], self.url_segments[3], self.url_segments[4], self.url_segments[5];

	local prefix = "Redfish:Chassis:"..instance..":LogServices:"..secondary_instance..":Entries"

	self:set_scope("Redfish:"..table.concat(self.url_segments,':'))
	-- Fill in Name and Description fields
	response["Name"] = "Log Service Entries Collection"
	response["Description"] = "Collection of entries for this log service"
	-- Search Redis for any Log Entries, and use response to form an array of IDs
	-- Log entry set can be huge, so we want to do $skip/$top now to limit DB access rather than after the fact;
	-- if $skip and $top are not given, we can enforce our own paging
	local start_index = self.query_parameters.skip or 0
	local end_index = CONFIG.DEFAULT_COLLECTION_LIMIT
	if self.query_parameters.top then
		end_index = start_index + self.query_parameters.top
	elseif self.query_parameters.skip then
		end_index = 0
	end
	-- Signal to RedfishHandler that $skip and $top have been processed, and need not be handled a second time
	self:clear_skip_top_flag()

	-- Because zrange lets you use negative arguments to index backwards from end of set, we need to be careful to not
	-- send [0, -1] (which retrieves the whole set) unless we mean it
	local expectEmptySet = self.query_parameters.top == "0"
	local entry_keys = {}
	-- Use zcard to find the total collection size
	local set_size = yield(redis:zcard(prefix..":SortedIDs"))
	-- Get the keys of intereset from Redis; zrange indices are inclusive, so we use end_index-1
	if set_size > 0 and not expectEmptySet then
		entry_keys = yield(redis:zrange(prefix..":SortedIDs", start_index, end_index-1))
	end

	-- Retrieve the Log Entry array from Redis via helper function
	response["Members"] = #entry_keys == 0 and entry_keys or self:get_instance_from_db(entry_keys, secondary_instance)
	response["Members@odata.count"] = set_size
	-- If there are remaining elements not retrieved, set the @odata.nextLink appropriately
	if end_index < set_size then
		local path = self:get_request().path
		response["Members@odata.nextLink"] = path .. "?$skip=" .. end_index .. "&$top=" .. CONFIG.DEFAULT_COLLECTION_LIMIT
	end

	-- Add OEM extension properties to the response
	response = self:oem_extend(response, "query." .. self:get_oem_collection_path())
	-- Set the OData context and type for the response
	self:set_context(CONSTANTS.LOGENTRY_COLLECTION_CONTEXT)
	self:set_type(CONSTANTS.LOG_ENTRY_COLLECTION_TYPE)
end

-- #### GET handler for Log Service Entries instance
function LogServiceEntriesHandler:get_instance(response)
	-- Set up the local space: gather url segments and set scope

	local collection, instance, secondary_collection, secondary_instance, inner_collection, inner_instance = 
		self.url_segments[1], self.url_segments[2], self.url_segments[3], self.url_segments[4], self.url_segments[5], self.url_segments[6];
	
	local redis_key = "Redfish:"..table.concat(self.url_segments,':')
	self:set_scope(redis_key)

	-- Retrieve the Log Entry from Redis via helper function
	local entry_array = self:get_instance_from_db(redis_key, secondary_instance) 
	_.extend(response, entry_array[1])

  	-- Check that data was found in Redis, if not we throw a 404 NOT FOUND
	self:assert_resource(entry_array[1])

	-- Set the OData context and type for the response
	local sL_table = _.keys(response)
	if #sL_table < 13 then
        local selectList = turbo.util.join(',', sL_table)
		self:set_context(CONSTANTS.LOGENTRY_INSTANCE_CONTEXT.."("..selectList..")")
	else
		self:set_context(CONSTANTS.LOGENTRY_INSTANCE_CONTEXT)
	end

	self:set_type(CONSTANTS.LOG_ENTRY_TYPE)
	-- Remove extraneous fields from the response
	utils.remove_nils(response)
end

-- #### Helper function for getting Log Service Entries from DB
-- TODO: Add OEM extension mechanism for Log Entries
function LogServiceEntriesHandler:get_instance_from_db(entry_keys, log_name)
	-- Allow singleton argument for entry_keys
	if type(entry_keys) == "string" then
		entry_keys = {entry_keys}
	end
	-- Get a connection with Redis DB
	local redis = self:get_db()
	
	-- Create a Redis pipeline and add commands for all Log Entry properties
	local pl = redis:pipeline()
	-- Use local access to avoid repeating table lookups on many loop iterations
	local mget = pl.mget
	local smembers = pl.smembers
	local remove_nils = utils.remove_nils
	local oem_array = oem_properties[log_name] or {}

	-- Helper function to retrieve oem properties for Log Entries
	local mget_oem_properties = function(entry_key)
		-- If oem_array is empty, don't do anything
		if _.is_empty(oem_array) then
			return
		end

		-- Function to map properties in oem extension to their redis keys
		local map_oem_to_redis = function(prop) 
			return entry_key .. ":oem:" .. prop.OEM .. ":" .. prop.Name 
		end

		-- Do the mapping
		mget_oem_query = _.map(oem_array, map_oem_to_redis)
		-- Add query to pipeline
		mget(pl, mget_oem_query)
	end

	for _index, entry_key in ipairs(entry_keys) do
		mget(pl, {
				entry_key .. ":Name",
				entry_key .. ":EntryType",
				entry_key .. ":OemRecordFormat",
				entry_key .. ":Severity",
				entry_key .. ":Created",
				entry_key .. ":EntryCode",
				entry_key .. ":SensorType",
				entry_key .. ":SensorNumber",
				entry_key .. ":Message",
				entry_key .. ":MessageId",
				entry_key .. ":OriginOfCondition",
				})
		smembers(pl, entry_key .. ":MessageArgs")
		mget_oem_properties(entry_key)
	end

	-- Run the Redis pipeline
	local redis_responses = yield(pl:run())
	self:assert_resource(redis_responses)
	local entry_array = {}
	-- For each entry retrieved from the DB, create an arry of Log Entries, converting types where necessary
	for i, entry_key in ipairs(entry_keys) do
		-- Unpack the data retrieved from Redis
		-- Indices used to unpack the redis data depend on whether we have OEM data
		local general = {}
		local msg_args = {}
		local oem_data = {}
		if _.is_empty(oem_array) then
			general = redis_responses[2*i - 1]
			msg_args = redis_responses[2*i]
			oem_data = nil
		else
			general = redis_responses[3*i - 2]
			msg_args = redis_responses[3*i - 1]
			oem_data = redis_responses[3*i]
		end

		-- Extract the entry's ID from the provided key
		local key_ary = entry_key:split(':')
		local id = key_ary[#key_ary]
		-- Create the Log Entry body
		entry_array[i] = {
			["Id"] = id,
			["Name"] = general[1],
			["EntryType"] = general[2],
			["OemRecordFormat"] = general[3],
			["Severity"] = general[4],
			["Created"] = general[5],
			["EntryCode"] = general[6],
			["SensorType"] = general[7],
			["SensorNumber"] = tonumber(general[8]),
			["Message"] = general[9],
			["MessageId"] = general[10],
			["MessageArgs"] = msg_args,
		}

		if general[11] then
			entry_array[i]["Links"] = {
				["OriginOfCondition"] = {["@odata.id"] = utils.getODataID(general[11])}
			}
		end

		-- If there is oem data, add it to the entry
		if oem_data and #oem_data > 0 then 
			-- Create an Oem object in the entry
			entry_array[i].Oem = {}
			-- Add an object with @odata.type for each Oem
			for oem_name, odata_type in pairs(oem_odata_type) do
				entry_array[i].Oem[oem_name] = {["@odata.type"] = odata_type}
			end
			for j, property in ipairs(oem_array) do
				-- Use the provided formatting function on data, or return without formatting if no function is found
				local format = oem_formatting[property.OEM][property.Type] or _.identity
				-- Here we prefer returning raw Redis value over formatting that returns nil
				local value = format(oem_data[j]) or oem_data[j]
				-- Add property to the Oem object
				entry_array[i].Oem[property.OEM][property.Name] = value
			end
		end
		-- If this array is to be used in a collection, the odata properties must be added manually
		if #entry_keys > 1 then
			entry_array[i]["@odata.id"] = utils.getODataID(entry_key)
			entry_array[i]["@odata.type"] = "#" .. CONSTANTS.LOG_ENTRY_TYPE
		end
		-- Remove extraneous fields from the entry
		remove_nils(entry_array[i])
	end

	-- Return the log entry array
	return entry_array
end

return LogServiceEntriesHandler