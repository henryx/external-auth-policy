# 3Scale External Auth Policy

Allows the service call to be authorized against an external service

## 1. Configuration

The configuration is built on two different sections:


A validation service configuration section containing the following parameters:

#### T01 - Validation service configuration section table
| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|validation_service_method | the HTTP method to be used for invoking the service, can be GET or POST | POST | YES |
|validation_service_url | the validation service url |  | YES |
|validation_service_params| the parameters to be passed to validation service call, See [Table T01.1](#t01---validation-service-configuration-section-table) for configuration details ||NO|
|validation_service_timeouts|the timeout configuration for validation service call, see [Table T01.2](#t012---validation-service-timeouts-configuration-table)||NO|
|allowed_status_codes|an array of status codes to be returned to the client, if empty return every response as-is, if specified every non-matching code is translated into a 500, a HTTP 200 always returns OK||NO|

~~~json

        "validation_service_configuration": {
          "validation_service_method": "POST",
          "validation_service_timeouts": {
           "connect_timeout": 500,
           "send_timeout": 500,
           "receive_timeout": 500
          },
          "validation_service_url": "http://my-auth-service.auth-app.svc.cluster.local/auth",
          "validation_service_params": [
           {
            "value_type": "liquid",
            "param": "uri",
            "value": "{{ original_request.uri }}"
           }
          ],
          "allowed_status_codes": [
            401,
            403
          ]
         }

~~~

the validation service params is an array of parameters allowing the user to add any number of parameters to be passed to the external service. The parameter values are rendered as templates and can be specified in plaintext or liquid following APICast standards.

#### T01.1 - Validation service params configuration table
| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|value_type | a string defining the type of the value, can be plain or liquid | plain | YES |
|param | the name of the parameter as it will be set in the service call |  | YES |
|value| the template or fiel value which will be rendered at runtime | | NO | 

for example in order to have a field named **uri** in the request payload containing the service uri:

~~~json

          "validation_service_params": [
           {
            "value_type": "liquid",
            "param": "uri",
            "value": "{{ original_request.uri }}"
           }
          ]
          
~~~

#### T01.2 - Validation service timeouts configuration table

| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|connect_timeout | service connection timeout threshold in milliseconds | 500 | NO |
|send_timeout | send timeout threshold in milliseconds | 500 | NO |
|receive_timeout| receive timeout threshold in milliseconds | 500 | NO|

the following sample sets every timeout to 500 milliseconds:

~~~json

          "validation_service_timeouts": {
           "connect_timeout": 500,
           "send_timeout": 500,
           "receive_timeout": 500
          }
          
~~~






and a second section containing the headers - related parameters

#### T02 - Header Parameters

| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|headers_to_copy | describe which headers should be copied to the Authorization Service, can be **ALL**, **None** or **Selected Headers**. If **Selected Headers** is specified a **selected_headers** section should be addedd| ALL | NO |
|selected_headers| This section conains the list of the headers to be extracted from the incoming call and passed to the authorization service, see [Table T02.1](#table-t021---selected-headers-configuration-section) for details | | NO |

|additional_headers | allows to put additional headers in the configuration | | NO |

~~~json

        "headers_configuration": {
          "headers_to_copy": "Selected Headers",
          "additional_headers": [
           {
            "value_type": "plain",
            "header": "Accept",
            "value": "application/custom.authorization.v1+json"
           },
           {
            "value_type": "plain",
            "value": "application/json",
            "header": "Content-Type"
           }
          ],
          "selected_headers": [
           {
            "action_if_missing": "Ignore",
            "header_name": "X-customHeader-01"
           },
           {
            "action_if_missing": "Fail",
            "header_name": "X-customHeader-02",
            "http_status": "401",
            "message": "missing X-customHeader-02 header"
           },
           {
            "action_if_missing": "Fail",
            "header_name": "X-customHeader-03",
            "http_status": "401",
            "message": "missing X-customHeader-03 header"
           }
          ]
         }

~~~

#### Table T02.1 - Selected Headers configuration section

the following parameters identifies the headers to be passed to the Authorization service and the behavior if the header is missing

| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|header_name | the header to be copied |  | YES |
|action_if_missing | The action to be performet if the header is missing, can be **Ignore**, **Set Empty** or **Fail**| Ignore | NO |
|http_status| the HTTP status code to be returned to the client if **action_if_missing** is set to **Fail** | 401 | NO|
|message| the error message to be returned to the client if **action_if_missing** is set to **Fail** | | NO|


~~~json

        "selected_headers": [
           {
            "action_if_missing": "Ignore",
            "header_name": "X-customHeader-01"
           },
           {
            "action_if_missing": "Fail",
            "header_name": "X-customHeader-02",
            "http_status": "401",
            "message": "missing X-customHeader-02 header"
           },
           {
            "action_if_missing": "Set Empty",
            "header_name": "X-customHeader-03"
           }
          ]
        
~~~

#### Table T02.2 - Additional Headers section

the additional headers section is an array of parameters allowing the user to add any number of headers to be passed to the external service. The parameter values are rendered as templates and can be specified in plaintext or liquid following APICast standards.

>**WARNING:**
>
> The headers specified in this section will override any header with the same name found in the selected_header

| parameter name      | parameter description |  default value |  mandatory   |
|---------------------|---------------------|-----------------|----------------|
|value_type | a string defining the type of the value, can be plain or liquid | plain | YES |
|header | the name of the header as it will be set in the service call |  | YES |
|value| the template or field value which will be rendered at runtime | | NO | 


~~~json

        "additional_headers": [
           {
            "value_type": "plain",
            "header": "Accept",
            "value": "application/custom.authorization.v1+json"
           },
           {
            "value_type": "plain",
            "value": "application/json",
            "header": "Content-Type"
           }

~~~

the full configuration sample can be found [here](#full-policy-configuration-sample) or inside the folder **samples** in the project

#### T03 - Cache Configuration

The cache configuration section enables in-memory caching of auth service responses. When a cache hit occurs, the external service is not invoked and the cached status code is returned immediately, reducing latency and load on the auth service.

> **NOTE:**
>
> The cache is per-worker (each nginx worker maintains its own independent cache). This means the effective cache size across the APICast pod is `cache_max_size × number_of_workers`.

| parameter name   | parameter description | default value | mandatory |
|------------------|-----------------------|---------------|-----------|
|cache_enabled | enables or disables response caching | false | NO |
|cache_ttl | time to live for cached entries in seconds | 60 | NO |
|cache_max_size | maximum number of entries per worker cache | 1000 | NO |
|cache_key_cookie | name of the session cookie whose value is used as cache key | session | NO |

The cache key is the value of the configured session cookie (read via `ngx.var["cookie_<name>"]`). If the cookie is absent from the request, caching is skipped for that call and the auth service is always invoked.

~~~json

        "cache_configuration": {
          "cache_enabled": true,
          "cache_ttl": 60,
          "cache_max_size": 1000,
          "cache_key_cookie": "JSESSIONID"
        }

~~~
      

## 2. Installation

To install the policy, a secret containing 
- apicast-policy.json
- external_auth_service.lua
- init.lua

files must be created:

~~~bash

oc create secret generic external-auth-policy --from-file=./init.lua --from-file=apicast-policy.json --from-file=external_auth_service.lua

~~~

the **external-auth-policy** secret name can be changed

after that the APIManager CR should be configured in order to mount the secret inside Staging and Production APICasts by putting the following section:

~~~yaml

      customPolicies:
      - name: external_auth_service
        secretRef:
          name: <name of the secret created in the previous step>
        version: "0.1"

~~~

inside the `stagingSpec` and the `productionSpec` sections of the yaml.

After that a rollout of the APICast pods will be automatically triggered by the operator. Once finished the policy will be available on 3Scale Administration portal to be configured.

## 3. Samples

### Full policy configuration sample

The following sample is a full policy configuration, it should be inserted inside the APICast proxy configuration json on the correct position in the policy_chain - the same snippet could be found [here](samples/sample-config.json)

~~~json

     {
      "name": "external_auth_service",
      "version": "0.1",
      "configuration": {
       "validation_service_configuration": {
        "validation_service_method": "POST",
        "validation_service_timeouts": {
         "request_timeout": 500,
         "connect_timeout": 500,
         "response_timeout": 500
        },
        "validation_service_url": "http://my-auth-service.auth-app.svc.cluster.local/auth",
        "validation_service_params": [
         {
          "value_type": "liquid",
          "param": "uri",
          "value": "{{ uri }}"
         }
        ],
        "allowed_status_codes": [
         401,
         403
        ]
       },
       "headers_configuration": {
        "headers_to_copy": "Selected Headers",
        "additional_headers": [
         {
          "value_type": "plain",
          "header": "Accept",
          "value": "application/custom.authorization.v1+json"
         },
         {
          "value_type": "plain",
          "value": "application/json",
          "header": "Content-Type"
         }
        ],
        "selected_headers": [
           {
            "action_if_missing": "Ignore",
            "header_name": "X-customHeader-01"
           },
           {
            "action_if_missing": "Fail",
            "header_name": "X-customHeader-02",
            "http_status": "401",
            "message": "missing X-customHeader-02 header"
           },
           {
            "action_if_missing": "Set Empty",
            "header_name": "X-customHeader-03"
           }
        ]
       },
       "cache_configuration": {
        "cache_enabled": true,
        "cache_ttl": 60,
        "cache_max_size": 1000,
        "cache_key_cookie": "JSESSIONID"
       }
      }
     }
    

~~~


### Full APIManager Resource Sample

The following sample is a full APIManager CR configuration - the same sample could be found [here](samples/apimanager-cr.yaml)

~~~yaml

apiVersion: apps.3scale.net/v1alpha1
kind: APIManager
metadata:
  annotations:
    apps.3scale.net/apimanager-threescale-version: "2.13"
    apps.3scale.net/threescale-operator-version: 0.10.1
  name: apimanager-test
  namespace: 3scale
spec:
  apicast:
    managementAPI: status
    openSSLVerify: false
    registryURL: http://apicast-staging:8090/policies
    responseCodes: true
    stagingSpec:
      customPolicies:
      - name: external_auth_service
        secretRef:
          name: external-auth-policy
        version: "0.1"
    productionSpec:
      customPolicies:
      - name: external_auth_service
        secretRef:
          name: external-auth-policy
        version: "0.1"
  appLabel: 3scale-api-management
  backend:
    cronSpec: {}
    listenerSpec: {}
    workerSpec: {}
  imageStreamTagImportInsecure: false
  resourceRequirementsEnabled: true
  system:
    appSpec: {}
    sidekiqSpec: {}
    sphinxSpec: {}
  tenantName: 3scale
  wildcardDomain: apps-crc.testing
  zync:
    appSpec: {}
    queSpec: {}


~~~

