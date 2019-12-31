# vera-VOTS
Vera Virtual Outdoor Temperature Sensor, modified

This version allows for three types of outdoor temperature sources and has improved zwave thermostat handling.

After installing the original VOTS plugin from the Vera App store, upload the L_VirtualOutdoorTemperature.lua to you Vera.

The TempSource variable controls the temperature input used. 1 is the standard Mios weather service, reporting in whole degrees only.

Set TempSource to 2 to use any other device or plugin that reports the outside temperature on your Vera and reload the Luup Engine. Then specify that device number in TempDeviceID. If it is a default temperature device you can leave TempVarName and TempVarSID as is. If not modify them accordingly.

Set TempSource to 3 for using the AmbientWeather API that is used for your local Ambient Weather station. Specify the apiKey and applicationKey. If the outside temperature is not reported, you have to specify the SensorNum (1-10) that reports the outside temperature.
