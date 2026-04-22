-- External Authorization Service policy
-- invokes an external service for authorization.


-- local function aliases

local ipairs = ipairs
local tonumber = tonumber
local TemplateString = require 'apicast.template_string'
local _M = require('apicast.policy').new('External Service Authorization')
local cjson = require('cjson')
local new = _M.new
local resty_env = require('resty.env')

-- HTTP client
local http = require('resty.http')

-- LRU cache
local lrucache = require('resty.lrucache')



-- default values

local default_value_type = 'plain' -- default type for template processing
local default_validation_service_method = 'POST' -- default http method for authorization service invocation
local default_missing_header_status = 401 -- default HTTP status code for denying by missing header 
local default_missing_header_message = "mandatory header is missing" -- default HTTP message for denying by missing header 
local default_service_timeout = 500 -- default timeout (in milliseconds)

-- logLevels

local DEBUG = ngx.DEBUG
local INFO = ngx.INFO
local WARN = ngx.WARN
local ERROR = ngx.ERR

--- function has_value: check if the given value is present inside a table 
---
---@param tab any @the table to check
---@param val any @the value to find
---@return boolean @true if value is present
---

local function has_value (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

local char_to_hex = function(c)
  return string.format("%%%02X", string.byte(c))
end

--- function urlencode encodes a variable with url standards replacing non stadard chars with http compatibile

local function urlencode(url)
  if url == nil then
    return ""
  end
  url = url:gsub("\n", "\r\n")
  url = url:gsub("([^%w ])", char_to_hex)
  url = url:gsub(" ", "+")
  return url
end

--- if APICAST_LOG_LEVEL is set to DEBUG prints the content of the given table
---@param node table @ the table to be printed
---

local function print_table(node)

    -- if APICAST_LOG_LEVEL is not DEBUG skip
    if resty_env.get("APICAST_LOG_LEVEL") ~= "debug" then
        return
    end

    local cache, stack, output = {}, {}, {}
    local depth = 1
    local output_str = "{\n"

    while true do
        local size = 0
        for k, v in pairs(node) do
            size = size + 1
        end

        local cur_index = 1
        for k, v in pairs(node) do
            if (cache[node] == nil) or (cur_index >= cache[node]) then

                if (string.find(output_str, "}", output_str:len())) then
                    output_str = output_str .. ",\n"
                elseif not (string.find(output_str, "\n", output_str:len())) then
                    output_str = output_str .. "\n"
                end

                -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
                table.insert(output, output_str)
                output_str = ""

                local key
                if (type(k) == "number" or type(k) == "boolean") then
                    key = "[" .. tostring(k) .. "]"
                else
                    key = "['" .. tostring(k) .. "']"
                end

                if (type(v) == "number" or type(v) == "boolean") then
                    output_str = output_str .. string.rep('\t', depth) .. key .. " = " .. tostring(v)
                elseif (type(v) == "table") then
                    output_str = output_str .. string.rep('\t', depth) .. key .. " = {\n"
                    table.insert(stack, node)
                    table.insert(stack, v)
                    cache[node] = cur_index + 1
                    break
                else
                    output_str = output_str .. string.rep('\t', depth) .. key .. " = '" .. tostring(v) .. "'"
                end

                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t', depth - 1) .. "}"
                else
                    output_str = output_str .. ","
                end
            else
                -- close the table
                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t', depth - 1) .. "}"
                end
            end

            cur_index = cur_index + 1
        end

        if (size == 0) then
            output_str = output_str .. "\n" .. string.rep('\t', depth - 1) .. "}"
        end

        if (#stack > 0) then
            node = stack[#stack]
            stack[#stack] = nil
            depth = cache[node] == nil and depth + 1 or depth - 1
        else
            break
        end
    end

    -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
    table.insert(output, output_str)
    output_str = table.concat(output)

    ngx.log(DEBUG, output_str)
end

--- function build_templates
--- trasform the value in a template of the given type (liquid or plain text)
---
---@param templates table @trasform the value in a template of the given type (liquid or plain text)
---@return table @the returned table is the input with an additional template_string for further processing
---

local function build_templates(templates)
    for _, template in ipairs(templates) do
        template.template_string = TemplateString.new(template.value, template.value_type or default_value_type)
    end
end


--- function build_cache_key: builds a deterministic cache key from the request parameters
---@param url string @ the service URL
---@param method string @ the HTTP method
---@param headers table @ the request headers
---@param args table @ the request arguments
---@return string @ the cache key

local function build_cache_key(url, method, headers, args)
    local parts = { url, method }

    local sorted_headers = {}
    for k, v in pairs(headers or {}) do
        table.insert(sorted_headers, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(sorted_headers)

    local sorted_args = {}
    for k, v in pairs(args or {}) do
        table.insert(sorted_args, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(sorted_args)

    table.insert(parts, table.concat(sorted_headers, "&"))
    table.insert(parts, table.concat(sorted_args, "&"))
    return table.concat(parts, "|")
end

--- function invokeService - Invokes an external service
--- can invoke HTTP GET and POST services
--- with a GET services the args will be appended to the querystring 
--- with a POST service the args will be sent in a JSON format
---
---@param serviceUrl string @ the URL for the service to be invoked
---@param args table @ the table containing the arguments 
---@param httpMethod string @ the HTTP method (can be GET or POST)
---@param headers table @ the HTTP HEADERS to be passed to the remote service 
---@param timeouts table @ a table containing the connect, send and read timeout -> {connect_timeout = 500, send_timeout = 500, read_timeout = 500}
---@return http_status_code: number, http_error: string, json_body: string @ the values returned from the service invocation
---

local function invokeService(serviceUrl, args, httpMethod, headers, timeouts)
    
    -- dump the function invocation informations
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: serviceUrl->', serviceUrl)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: args')
    
    print_table(args)
    
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: httpMethod->', httpMethod)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: headers')
    
    print_table(headers)

    local httpc = http.new()
    local http_status_code
    local http_error
    local json_body
    local fullApiURL
    local params = {}

    if httpMethod == 'GET' then
        
        if args then
            -- creating the HTTP GET service uri appending the arguments
            argstring=""
            for k, v in pairs(args) do
                argstring = argstring .. "&" .. k .. "=" .. urlencode(v)
            end
            argstring= string.sub(argstring, 2)
            fullApiURL = serviceUrl .. "?" .. argstring .. ""
        else
            fullApiURL = serviceUrl
        end

    elseif httpMethod == 'POST' then
        
        fullApiURL = serviceUrl
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: creating body')
        cjson.encode_escape_forward_slash(false)
        params["body"] = cjson.encode(args)

    end
    
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: setting method, headers etc..')
    
    params["method"] = httpMethod
    params["headers"] = headers
    params["ssl_verify"] = resty_env.enabled('OPENSSL_VERIFY')
    
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: invoking API at url->', fullApiURL)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: invoking API with method->', httpMethod)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invokeService: invoking API with params->')
    
    print_table(params)

    httpc:set_timeouts(timeouts.connect_timeout, timeouts.send_timeout, timeouts.read_timeout)

    -- service invocation
    local res, err = httpc:request_uri(fullApiURL, params)
    
    if err then
        -- an error occurred while invoking the service, returning a 500 - internal server error with err as description
        ngx.log(WARN, err)

        return 500, err, nil    
    end
    
    -- service invocation ok, processing the return values

    http_status_code = res.status
    http_error = err or res.reason
    json_body = res.body

    -- Use res.body to access the response
    -- When the request is successful, res will contain the following fields:
    -- status The status code.
    -- reason The status reason phrase.
    -- headers A table of headers. Multiple headers with the same field name will be presented as a table of values.
    -- body The response body
    local logLevel
    if (http_status_code == 200) then
        logLevel = DEBUG
    else
        logLevel = WARN
    end
    
    ngx.log(logLevel, '- ExternalAuthServicePolicy : invokeAPI: API invoked: http_status_code', http_status_code)
    ngx.log(logLevel, '- ExternalAuthServicePolicy : invokeAPI: API invoked: http_error', http_error)
    ngx.log(logLevel, '- ExternalAuthServicePolicy : invokeAPI: API invoked: json_body', json_body)
    
    return http_status_code, http_error, json_body;
end

-- initialize policy configuration

function _M.new(config)

    ngx.log(DEBUG, 'initializing configuration.... ')
    local self = new(config)

    self.config = config or {}

    -- validation service configuration parameters 

    self.validation_service_url = config.validation_service_configuration.validation_service_url
    self.validation_service_method = config.validation_service_configuration.validation_service_method or
                                         default_validation_service_method
    self.validation_service_params = config.validation_service_configuration.validation_service_params or {}

    self.allowed_status_codes = config.validation_service_configuration.allowed_status_codes or {}
    -- validation service timeouts parameters

    local service_timeouts = config.validation_service_configuration.validation_service_timeouts or {}

    self.timeouts = {
        connect_timeout = service_timeouts.connect_timeout or default_service_timeout,
        send_timeout = service_timeouts.send_timeout or default_service_timeout,
        read_timeout = service_timeouts.read_timeout or default_service_timeout
    }

    -- build templates used as service arguments

    build_templates(self.validation_service_params)
    
    -- headers section

    self.headers_to_copy = config.headers_configuration.headers_to_copy or "ALL"

    if self.headers_to_copy == "Selected Headers" then
        self.selected_headers = config.headers_configuration.selected_headers or {}
    else
        self.selected_headers = {}
    end

    self.additional_headers = config.headers_configuration.additional_headers or {}

    build_templates(self.additional_headers)
    
    -- caching section

    local cache_config = config.cache_configuration or {}
    self.cache_enabled = cache_config.cache_enabled or false
    self.cache_ttl = cache_config.cache_ttl or 60

    if self.cache_enabled then
        local cache_max_size = cache_config.cache_max_size or 1000
        local c, err = lrucache.new(cache_max_size)
        if c then
            self.cache = c
            ngx.log(DEBUG, '- ExternalAuthServicePolicy : cache initialized, max_size=', cache_max_size, ' ttl=', self.cache_ttl)
        else
            ngx.log(ERROR, '- ExternalAuthServicePolicy : failed to create cache: ', err, ' - caching disabled')
            self.cache_enabled = false
        end
    end

    ngx.log(ngx.DEBUG, 'initializing.... end ')
    
    return self
end

--- find_headers retrieve the http headers to be sent to auth request
---@param headers table @the request http headers
---@param headers_to_copy any @the configuration object containing the headers to be found
---@return error: table, headers: table @ the 1st table describes if the lookup fails and return the configured http code and error (mandatory header missing and Fail set to true) the table is the headers array
---

local function find_headers(headers, headers_to_copy)

    ngx.log(DEBUG, '- ExternalAuthServicePolicy : find_headers')
    print_table(headers)
    print_table(headers_to_copy)
    
    local output = {}
    
    -- find the configured headers (when the headers_to_copy array in the configuration is not empty)

    for _, header in ipairs(headers_to_copy) do
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : finding header -> ', header.header_name)

        local header_to_insert = headers[header.header_name] or nil

        if header_to_insert == nil then
            
            -- header not found, check the configured behavior

            if header.action_if_missing == 'Set Empty' then
            
                output[header.header_name] = ''
                ngx.log(WARN, '- ExternalAuthServicePolicy : header ' .. header.header_name ..
                    ' is missing, it will be populated with an empty string according to policy configuration')
            
            elseif header.action_if_missing == 'Fail' then
            
                ngx.log(ERROR, '- ExternalAuthServicePolicy : header ' .. header.header_name ..
                    ' is missing, since it\'s mandatory. returning an error to the client...')
                local error = {
                    http_status = tonumber(header.http_status or default_missing_header_status),
                    error_message = header.message or default_missing_header_message
                }
                return error, nil
            
            else
            
                ngx.log(WARN, '- ExternalAuthServicePolicy : header ' .. header.header_name ..
                    ' is missing, it will be skipped')
            
            end
        else

            output[header.header_name] = headers[header.header_name]
            ngx.log(DEBUG, '- ExternalAuthServicePolicy : header ' .. header.header_name .. ' found with value ' ..
                headers[header.header_name])

        end
    end
    return nil, output
end

--- func build_request_headers: create the headers table to be passed to validation service by merging the selected headers and the additional
---@param self any @current module instance representation
---@param context any @context for the current call, used for template population
---@param headers any @http headers for the incoming request
---@param additional_headers any @http headers to be appended to the outgoing request, if any header is already present will be overridden
---@return fail: table, output:table @fail: the error representation, output: the list of the headers to be used when invoking the auth service
---

local function build_request_headers(self, context, headers, additional_headers)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : build_request_headers')
    print_table(self)
    print_table(context)
    print_table(headers)
    print_table(additional_headers)
    local output
    local fail
    
    if self.headers_to_copy == "ALL" then
        -- copy every header
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : copying every header')
        output = headers;
    elseif self.headers_to_copy == "Selected Headers" then
        -- copy selected headers only
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : copying only selected headers')
        ngx.log(DEBUG, 'headers -> ', headers, ' headers_to_copy->', self.selected_headers)
        fail, output = find_headers(headers, self.selected_headers)
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : header copy: fail ->', fail, ' output->', output)
    else
        -- don't copy any header
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : no headers will be copied')
        output = {}
        fail = nil
    end

    -- changed header names in lowercase in order to avoid overlaps (ngnix stores them lowercase)
    if (not fail) then
        -- adding the additional headers (if any)
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : adding additional headers')
        for _, header in ipairs(additional_headers) do
            local header_name=string.lower(header.header)
            output[header_name] = header.template_string:render(context)
            ngx.log(DEBUG, '- ExternalAuthServicePolicy : added request header: ' .. header_name .. 'with value ' ..
                output[header_name])
        end
    end

    -- 2025-03-21 dealing with different cases headers
    -- removing Content-Lenght header to avoid conflicts
    if output ~= nil then
        for h_name, h_vlaue in pairs(output) do
            if string.lower(h_name) == "content-length" then
                ngx.log(INFO, '- ExternalAuthServicePolicy : removing Content-Lenght header in order to avoid conflicts')
                output[h_name] = nil
            end
        end
    end
    
    return fail, output

end


--- func build_request_args builds the request arguments by rendering the given templates
---@param self any @current module instance representation
---@param context any @context for the current call, used for template population
---@param params any @params for the incoming request in a template format
---@return output: table @table containing the processed arguments
---

local function build_request_args(self, context, params)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : build_request_args')
    print_table(self)
    print_table(context)
    print_table(params)

    local output = {}
    for _, param in ipairs(params) do
        output[param.param] = param.template_string:render(context)
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : added request parameter: ' .. param.param .. 'with value ' ..
            output[param.param])
    end
    print_table(output)
    return output
end

--- function access
--- main policy method:
--- - extract the headers from the incoming request
--- - build the headers for the auth service request
---     - if a header is missing and it's mandatory returns the configured HTTP status code and message
--- - build the arguments for the auth service request
--- - invokes the remote service
--- - if the remote service returns a 200 APICast can continue with further processing
--- - if the remote service returns a code different than 200 or an error, APICast execution is interrupted and the error is returned to the client.
---@param context table @http context for the call
---

function _M:access(context)
    local headers
    local header_error
    local service_headers
    local service_args
    local response_status_code
    local response_error
    local response_body

    ngx.log(DEBUG, '- ExternalAuthServicePolicy : start')
    headers = ngx.req.get_headers() or {}

    ngx.log(DEBUG, '- ExternalAuthServicePolicy : validating headers')
    header_error, service_headers = build_request_headers(self, context, ngx.req.get_headers() or {},
        self.additional_headers)

    if header_error then
        ngx.log(ERROR, '- ExternalAuthServicePolicy : headers validation failed: ', header_error.message)
        ngx.status = header_error.http_status
        ngx.say(header_error.error_message)
        return ngx.exit(ngx.status)
    end

    ngx.log(DEBUG, '- ExternalAuthServicePolicy : creating requests')
    service_args = build_request_args(self, context, self.validation_service_params)

    -- cache lookup
    local cache_key
    if self.cache_enabled then
        cache_key = build_cache_key(self.validation_service_url, self.validation_service_method, service_headers, service_args)
        local cached_status = self.cache:get(cache_key)
        if cached_status ~= nil then
            ngx.log(DEBUG, '- ExternalAuthServicePolicy : cache hit, status-> ', cached_status)
            if cached_status == 200 then
                ngx.log(DEBUG, '- ExternalAuthServicePolicy : cache hit: validation success!')
                return
            else
                local returned_code
                if (#self.allowed_status_codes == 0) or has_value(self.allowed_status_codes, cached_status) then
                    returned_code = cached_status
                else
                    returned_code = 500
                end
                ngx.status = returned_code
                return ngx.exit(ngx.status)
            end
        end
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : cache miss, invoking service')
    end

    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invoking service')
    response_status_code, response_error, response_body = invokeService(self.validation_service_url, service_args,
        self.validation_service_method, service_headers, self.timeouts)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invoked service response_status_code-> ', response_status_code)
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invoked service response_error-> ', response_error or '')
    ngx.log(DEBUG, '- ExternalAuthServicePolicy : invoked service response_body-> ', response_body or '')

    -- store result in cache
    if self.cache_enabled and cache_key then
        self.cache:set(cache_key, response_status_code, self.cache_ttl)
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : cached status ', response_status_code, ' for ', self.cache_ttl, 's')
    end

    if (response_status_code ~= 200) then
        local returned_code
        local returned_message
        ngx.log(ERROR, '- ExternalAuthServicePolicy : service invocation failed! http_status: ', response_status_code,
            ', response_error: ', response_error or '', " response body: ", response_body or '')
        
        if (#self.allowed_status_codes == 0) or has_value(self.allowed_status_codes,response_status_code) then
            returned_code = response_status_code
            returned_message = response_error or ''
        else
            returned_code = 500
            returned_message = ''
        end

        ngx.status = returned_code
        ngx.say(returned_message )
        return ngx.exit(ngx.status)
    else
        ngx.log(DEBUG, '- ExternalAuthServicePolicy : validation success!')
    end

end

return _M
