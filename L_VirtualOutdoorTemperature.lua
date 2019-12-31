-- $Revision: 19 $
-- $Date: 2019-12-30 $
-- Modified for other temp devices by Rene Boer
-- Use for Other temperature devices or ambientweather.docs.apiary.io.close
-- rev19 changes:
--					Fixes for ambient weather source.
--					Allow to specify sensor number for ambient weather source. Zero if default (tempf).
-- rev18 changes:
--					Fix for handling negative temperatures for zwave thermostats.
--					Farhenheit are sent in whole numbers to zwave thermostats.
--					Fixes in GetWeatherSettings
-- Some info on setting temp in zwave thermostats https://forums.indigodomo.com/viewtopic.php?f=58&t=16025#p115284


local dkjson = require("dkjson")
local nixio = require("nixio")

local log = luup.log

-- Flags
local DEBUG_MODE = false

-- Constants
local SID = {
	VOTS = "urn:micasaverde-com:serviceId:VOTS1",
	TMP  = "urn:upnp-org:serviceId:TemperatureSensor1",
	ZWN  = "urn:micasaverde-com:serviceId:ZWaveNetwork1",
	ZGN  = "urn:micasaverde-com:serviceId:ZigbeeNetwork1"
}
local TASK = {
	ERROR       = 2,
	ERROR_ALARM = -2,
	ERROR_STOP  = -4,
	SUCCESS     = 4,
	BUSY        = 1
}
local DISPLAY_SECONDS = 10
local MIN_UPDATE_INTERVAL = 1200 -- seconds
local WGET_TIMEOUT = 10
local ZWAVE_THERMOSTAT_PNP_ID = "4711"
local ZIGBEE_THERMOSTAT_PNP_ID = "6271"
local ZIGBEE_HEATER_PNP_ID = "7131"
local SRC_MIOS = 1
local SRC_DEV = 2
local SRC_AMB = 3

-- Globals
local g_votsDevice = nil
local g_taskHandle = -1
local g_lastTask = os.time() -- The time when the status message was last updated.
local g_zwaveThermostats = {}
local g_zigbeeThermostats = {}
local g_weatherSettings = {}
local g_updateInterval


local function debug (text)
	if DEBUG_MODE then
		log(text)
	end
end


function ClearTask()
	if (os.time() - g_lastTask >= DISPLAY_SECONDS) then
		if lug_language == "fr" then
			luup.task("Effancer...", TASK.SUCCESS, "VOTS", g_taskHandle)
		else
			luup.task("Clearing...", TASK.SUCCESS, "VOTS", g_taskHandle)
		end
	end
	debug("VOTS::ClearTask> Clearing task... ")
end


function DisplayMessage (text, mode)
	if mode == TASK.ERROR_ALARM or mode == TASK.ERROR_STOP then
		luup.task(text, TASK.ERROR, "VOTS", g_taskHandle)
		return
	end
	luup.task(text, mode, "VOTS", g_taskHandle)
	-- Set message timeout.
	g_lastTask = os.time()
	luup.call_delay("ClearTask", DISPLAY_SECONDS)
end


local function UrlEncode (s)
	s = s:gsub("\n", "\r\n")
	s = s:gsub("([^%w])", function (c)
							  return string.format("%%%02X", string.byte(c))
						  end)
	return s
end


-- Rounds a number to the nearest multiple of 'step'.
-- Examples: value = 1.65, step = 0.5 : rounded value = 1.5
--           value = 1.65, step = 1   : rounded value = 2
--           value = 1.20, step = 0.25: rounded value = 1.25
function math.round (value, step)
	step = step or 1
	return math.floor(1/step * (value + step/2)) / (1/step)
end


local function FtoC (fhTemp)
	return (fhTemp - 32) / 1.8
end


local function SetZWaveThermostatOutdoorTemperature (temp, tempFormat)
	local data = "0x31 0x05 0x01 0x"
	local tempHex, tempSignBit
	local temperature = tonumber(temp)
	if not temperature then
		log("VOTS::SetZWaveThermostatOutdoorTemperature> Invalid temperature: ".. temp, 1)
		return
	end
	if string.lower(tempFormat) == "c" then
		-- For celcius report one digit with 0.5 degree steps.
		temperature = math.round(temperature, 0.5) * 10
		tempSignBit = "22"
	else
		-- For Farhenheit use whole degrees.
		temperature = math.round(temperature, 1)
		tempSignBit = "0A"
	end
	if temperature >= 0 then
		-- Positive is 0 - 0x7FFF
		tempHex = string.format('%04X', temperature)
	else
		-- Negative is 0xFFFF (-1), to 0x8000
		tempHex = string.format('%04X', 0xFFFF + temperature)
	end
	data = data .. tempSignBit .." 0x".. tempHex:sub(1,2) .." 0x".. tempHex:sub(3,4)
	for _, devNum in pairs(g_zwaveThermostats) do
		local node = luup.attr_get("altid", devNum) or ""
		if node == "" then
			log("VOTS::SetZWaveThermostatOutdoorTemperature> Failed to get altid for device ".. devNum, 1)
		else
			log("VOTS::SetZWaveThermostatOutdoorTemperature> Sending data ".. data .." to device ".. devNum ..", node ".. node)
			luup.call_action(SID.ZWN, "SendData", { Node=node, Data=data }, 1)
		end
	end
end


local function SetZigBeeThermostatOutdoorTemperature (temp, tempFormat)
	local temperature = tonumber(temp)
	if not temperature then
		log("VOTS::SetZigBeeThermostatOutdoorTemperature> Invalid temperature: ".. temp, 1)
		return
	end
	-- In ZigBee all value units are in the metric system, so temperature values are always in Celsius.
	-- Resolution is 0.01 C.
	if string.lower(tempFormat) == "f" then
		temperature = math.round(FtoC(temperature), 0.01)
	end
	-- The temperature must be an integer, so 26.33 => 2633.
	temperature = temperature * 100
	local firstByte = nixio.bit.band(temperature, 255) -- LSB
	local secondByte = nixio.bit.rshift(temperature, 8) -- MSB
	local data = "0x01 0x40 0x29 ".. string.format("0x%02x 0x%02x", firstByte, secondByte)
	for _, devNum in pairs(g_zigbeeThermostats) do
		log("VOTS::SetZigBeeThermostatOutdoorTemperature> Sending data ".. data .." to device ".. devNum)
		luup.call_action(SID.ZGN, "SendData",
			{
				Node = devNum,
				FrameControl = 16,
				Cluster = 513,
				Command = 2,
				ManufacturerCode = 0,
				Data = data
			}, 2)
	end
end


local function SetOutdoorTemperature (temp)
	local currentTemp = luup.variable_get(SID.TMP, "CurrentTemperature", g_votsDevice)
	if currentTemp ~= temp then
		luup.variable_set(SID.TMP, "CurrentTemperature", temp, g_votsDevice)
	end
end


local function GetWeatherSettings()
	log("VOTS::GetWeatherSettings> Get weather settings")
	local url = "http://127.0.0.1:3480/data_request?id=user_data&output_format=json"
	local status, content = luup.inet.wget(url, WGET_TIMEOUT)
	if not content or status ~= 0 then
		log("VOTS::GetWeatherSettings> Failed to get user_data", 1)
		return false
	end
	local data, pos, err = dkjson.decode(content)
	if not data then
		log("VOTS::GetWeatherSettings> Failed to decode user_data with error: "..(err or ""), 1)
		return false
	end
	if not data.weatherSettings then
		log("VOTS::GetWeatherSettings> Weather settings not set in the user_data", 1)
		return false
	end
	g_weatherSettings.tempFormat = data.weatherSettings.tempFormat or ""
	g_weatherSettings.weatherCity = data.weatherSettings.weatherCity or ""
	g_weatherSettings.weatherCountry = data.weatherSettings.weatherCountry or ""
	if g_weatherSettings.tempFormat == "" or g_weatherSettings.weatherCity == "" or g_weatherSettings.weatherCountry == "" then
		log(string.format("VOTS::GetWeatherSettings> Missing or empty weather settings: tempFormat=%s, weatherCity=%s, weatherCountry=%s",
			g_weatherSettings.tempFormat, g_weatherSettings.weatherCity, g_weatherSettings.weatherCountry), 1)
		return false
	end
	log(string.format("VOTS::GetWeatherSettings> Got settings: tempFormat=%s, weatherCity=%s, weatherCountry=%s",
		g_weatherSettings.tempFormat, g_weatherSettings.weatherCity, g_weatherSettings.weatherCountry))
	if g_weatherSettings.tempSource == SRC_DEV then
		if g_weatherSettings.tempVarSID == "" or g_weatherSettings.tempVarName == "" or g_weatherSettings.tempDeviceID == 0 then
			log(string.format("VOTS::GetWeatherSettings> Missing or empty weather settings: tempVarSID=%s, tempVarName=%s, tempDeviceID=%s",
				g_weatherSettings.tempVarSID, g_weatherSettings.tempVarName, g_weatherSettings.tempDeviceID), 1)
			return false
		end
	elseif g_weatherSettings.tempSource == SRC_AMB then
		if g_weatherSettings.applicationKey == "" or g_weatherSettings.apiKey == "" or g_weatherSettings.sensorNum == "" then
			log(string.format("VOTS::GetWeatherSettings> Missing or empty weather settings: applicationKey=%s, apiKey=%s, sensorNum=%s",
				g_weatherSettings.applicationKey, g_weatherSettings.apiKey, g_weatherSettings.sensorNum), 1)
			return false
		end
	end
	return true
end


local function GetTemperature()
	local temp, tempFormat = "0.0", g_weatherSettings.tempFormat
	
	-- Check for temp source
	if g_weatherSettings.tempSource == SRC_MIOS then
		local url = string.format("http://weather.mios.com?tempFormat=%s&cityWeather=%s&countryWeather=%s",
			g_weatherSettings.tempFormat, UrlEncode(g_weatherSettings.weatherCity), UrlEncode(g_weatherSettings.weatherCountry))
		log("VOTS::GetTemperature> Get temperature with URL: ".. url)
		local status, content = luup.inet.wget(url, WGET_TIMEOUT)
		local data, pos, err = dkjson.decode(content)
		if not data then
			log("VOTS::GetTemperature> Failed to decode weather response with error: "..(err or ""), 1)
			return false
		end
		if data.errors then
			log("VOTS::GetTemperature> Invalid response from server: ".. content, 1)
			return false
		end
		temp = data.temp .. ".0"
		tempFormat = data.tempFormat
	elseif g_weatherSettings.tempSource == SRC_DEV then
		temp = luup.variable_get(g_weatherSettings.tempVarSID, g_weatherSettings.tempVarName, g_weatherSettings.tempDeviceID) or "0.0"
	elseif g_weatherSettings.tempSource == SRC_AMB then
		local url = string.format("https://api.ambientweather.net/v1/devices?applicationKey=%s&apiKey=%s",
			g_weatherSettings.applicationKey, g_weatherSettings.apiKey)
		log("VOTS::GetTemperature> Get temperature with URL: ".. url)
		local status, content = luup.inet.wget(url, WGET_TIMEOUT)
		local data, pos, err = dkjson.decode(content)
		if not data then
			log("VOTS::GetTemperature> Failed to decode weather response with error: "..(err or ""), 1)
			return false
		end
		data = data[1]
		if not data then
			log("VOTS::GetTemperature> Failed to decode weather response with error: no device found", 1)
			return false
		end
		if tonumber(g_weatherSettings.sensorNum) > 0 then
			-- Get for specific sensor number.
			temp = data.lastData["temp"..g_weatherSettings.sensorNum.."f"] or 0  
		else
			temp = data.lastData.tempf or 0  
		end
		if string.lower(tempFormat) == "c" then
			-- Ambient weather always returns value in Fahrenheit (?), so convert to Celsius rounded to 0.1.
			temp = math.round(FtoC(temp), 0.1)
		end	
		temp = tostring(temp)
	end
	if temp:find(".") == nil then temp = temp .. ".0" end
	log("VOTS::GetTemperature> Got temperature: ".. temp)
	return true, temp, tempFormat
end


function UpdateValues()
	local status, temperature, temperatureFormat = GetTemperature()
	if not status then
		log("VOTS::UpdateValues> Failed to get temperature", 1)
		luup.call_delay("UpdateValues", g_updateInterval)
		return false
	end
	SetOutdoorTemperature(temperature)
	if #g_zwaveThermostats == 0 then
		debug("VOTS::UpdateValues> No Z-Wave thermostat to update")
	else
		SetZWaveThermostatOutdoorTemperature(temperature, temperatureFormat)
	end
	if #g_zigbeeThermostats == 0 then
		debug("VOTS::UpdateValues> No ZigBee thermostat to update")
	else
		SetZigBeeThermostatOutdoorTemperature(temperature, temperatureFormat)
	end

	luup.call_delay("UpdateValues", g_updateInterval)
	return true
end


local function GetThermostatDevices()
	log("VOTS::GetThermostatDevices> Get thermostat devices")
	for dev, attr in pairs(luup.devices) do
		local pnpId = luup.attr_get("pnp", dev)
		if pnpId == ZWAVE_THERMOSTAT_PNP_ID then
			table.insert(g_zwaveThermostats, dev)
		elseif pnpId == ZIGBEE_THERMOSTAT_PNP_ID or pnpId == ZIGBEE_HEATER_PNP_ID then
			table.insert(g_zigbeeThermostats, dev)
		end
	end
	log("VOTS::GetThermostatDevices> Found Z-Wave thermostats: ".. table.concat(g_zwaveThermostats, ","))
	log("VOTS::GetThermostatDevices> Found ZigBee thermostats: ".. table.concat(g_zigbeeThermostats, ","))
end


local function GetPluginSettings()
	local debugMode = luup.variable_get(SID.VOTS, "DebugMode", g_votsDevice) or ""
	if debugMode == "" then
		luup.variable_set(SID.VOTS, "DebugMode", "0", g_votsDevice)
	end
	DEBUG_MODE = (debugMode == "1")
	log("VOTS::GetPluginSettings> Debug mode "..(DEBUG_MODE and "enabled" or "disabled"))

	local updateInterval = luup.variable_get(SID.VOTS, "UpdateInterval", g_votsDevice) or ""
	updateInterval = tonumber(updateInterval) or 0
	if updateInterval < MIN_UPDATE_INTERVAL then
		updateInterval = MIN_UPDATE_INTERVAL
		luup.variable_set(SID.VOTS, "UpdateInterval", updateInterval, g_votsDevice)
	end
	debug("VOTS::GetPluginSettings> UpdateInterval = ".. updateInterval )
	g_updateInterval = updateInterval
	-- RB Additional for alt sources
	local tempSource = luup.variable_get(SID.VOTS, "TempSource", g_votsDevice) or ""
	tempSource = tonumber(tempSource) or 0
	if tempSource == 0 then
		tempSource = SRC_MIOS
		luup.variable_set(SID.VOTS, "TempSource", tempSource, g_votsDevice)
	end
	debug("VOTS::GetPluginSettings> TempSource = ".. tempSource )
	g_weatherSettings.tempSource = tempSource
	if tempSource == SRC_DEV then
		local tempDeviceID = luup.variable_get(SID.VOTS, "TempDeviceID", g_votsDevice) or "-1"
		tempDeviceID = tonumber(tempDeviceID) or -1
		if tempDeviceID == -1 then
			tempDeviceID = 0
			luup.variable_set(SID.VOTS, "TempDeviceID", tempDeviceID, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> TempDeviceID = ".. tempDeviceID )
		g_weatherSettings.tempDeviceID = tempDeviceID
		local tempVarName = luup.variable_get(SID.VOTS, "TempVarName", g_votsDevice) or ""
		if tempVarName == "" then
			tempVarName = "CurrentTemperature"
			luup.variable_set(SID.VOTS, "TempVarName", tempVarName, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> TempVarName = ".. tempVarName )
		g_weatherSettings.tempVarName = tempVarName
		local tempVarSID = luup.variable_get(SID.VOTS, "TempVarSID", g_votsDevice) or ""
		if tempVarSID == "" then
			tempVarSID = SID.TMP
			luup.variable_set(SID.VOTS, "TempVarSID", tempVarSID, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> TempVarSID = ".. tempVarSID )
		g_weatherSettings.tempVarSID = tempVarSID
	elseif tempSource == SRC_AMB then
		local applicationKey = luup.variable_get(SID.VOTS, "ApplicationKey", g_votsDevice) or "-"
		if applicationKey == "-" then
			applicationKey = ""
			luup.variable_set(SID.VOTS, "ApplicationKey", applicationKey, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> ApplicationKey = ".. applicationKey )
		g_weatherSettings.applicationKey = applicationKey
		local apiKey = luup.variable_get(SID.VOTS, "ApiKey", g_votsDevice) or "-"
		if apiKey == "-" then
			apiKey = ""
			luup.variable_set(SID.VOTS, "ApiKey", apiKey, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> ApiKey = ".. apiKey )
		g_weatherSettings.apiKey = apiKey
		local sensorNum = luup.variable_get(SID.VOTS, "SensorNum", g_votsDevice) or "-"
		if sensorNum == "-" then
			sensorNum = "0"
			luup.variable_set(SID.VOTS, "SensorNum", sensorNum, g_votsDevice)
		end
		debug("VOTS::GetPluginSettings> SensorNum = ".. sensorNum )
		g_weatherSettings.sensorNum = sensorNum
	end
end


local function main()
	log("VOTS::main> Starting up...")
	if not dkjson or type(dkjson) ~= "table" then
		log("VOTS::main> Failed to load dkjson.lua")
		luup.task("ERROR Failed to load dkjson.lua", TASK.BUSY, "VOTS", -1)
		return false
	end
	g_taskHandle = luup.task("Starting up...", TASK.BUSY, "VOTS", -1)
	for dev, attr in pairs(luup.devices) do
		if attr.device_type == "urn:schemas-micasaverde-com:device:VOTS:1" then
			g_votsDevice = dev
			break
		end
	end
	if g_votsDevice == nil then
		log("VOTS::main> Create device")
		local devNum = luup.create_device(
			"", -- Device type
			"VOTD", -- altid
			"Virtual Outdoor Temperature Sensor", -- Device name
			"D_VirtualOutdoorTemperature1.xml", -- UPnP device file
			"", -- Implementation file
			"", -- IP
			"", -- MAC
			false, -- Hidden
			false, -- Invisible
			0,  -- Parent device ID
			0,  -- Room number
			0,  -- Plugin ID
			",category_num=17", -- Attributes and variables
			0,  -- pnp ID
			"", -- nochildsync
			"", -- AES key
			true, -- Reload
			false) -- nodupid

		log("VOTS::main> Created device ".. devNum)
		log("VOTS::main> Startup OK")
		return true
	end
	GetPluginSettings()
	if not GetWeatherSettings() then
		log("VOTS::main> Failed to get weather settings")
		DisplayMessage("Failed to get weather settings", TASK.BUSY)
		return false
	end
	GetThermostatDevices()
	if not UpdateValues() then
		log("VOTS::main> Failed to update values")
		DisplayMessage("Failed to update values", TASK.BUSY)
		return false
	end
	log("VOTS::main> Startup OK")
	DisplayMessage("Startup OK", TASK.BUSY)
	return true
end

main()
