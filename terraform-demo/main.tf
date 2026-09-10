terraform {
  required_version = ">= 1.5.0"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 4.16"
    }
  }
}

provider "datadog" {
  api_url = "https://api.datadoghq.com/"
  api_key = var.dd_api_key
  app_key = var.dd_app_key
}

variable "dd_api_key" {
  description = "Datadog API key"
  type        = string
  sensitive   = true
}

variable "dd_app_key" {
  description = "Datadog APP key"
  type        = string
  sensitive   = true
}

resource "datadog_observability_pipeline" "syslog_demo" {
  config {
    destination {
      id     = "destination-splunk-hec-01"
      inputs = ["processor-group-pii-redaction"]
      splunk_hec {
        auto_extract_timestamp = false
        encoding               = "json"
      }
    }
    pipeline_type = "logs"
    processor_group {
      display_name = "Extract Syslog Structured Data"
      enabled      = true
      id           = "processor-group-extract-sd-01"
      include      = "*"
      inputs       = ["source-syslog-01"]
      processor {
        custom_processor {
          remap {
            drop_on_error = false
            enabled       = true
            include       = "*"
            name          = "Extract structured data fields"
            source        = <<-EOF
            sd = ."enrichment@49312"
            if is_object(sd) {
              .ip_address = del(."enrichment@49312".ip_address)
              .accountnumber = del(."enrichment@49312".account_id)
              .host_name = del(."enrichment@49312".host_name)
              .asset_id = del(."enrichment@49312".asset_id)
              .job_id = del(."enrichment@49312".job_id)
              v = del(."enrichment@49312".source)
              if v != null && !exists(.source) { .source = v }
              v = del(."enrichment@49312".log_type)
              if v != null { .log_type = v }
              v = del(."enrichment@49312".subtype)
              if v != null { .subtype = v }
              v = del(."enrichment@49312"."message.type")
              if v != null { .message_type = v }
              v = del(."enrichment@49312"."message.subtype")
              if v != null { .message_subtype = v }
              v = del(."enrichment@49312"."message.action")
              if v != null { .message_action = v }
              v = del(."enrichment@49312"."message.status")
              if v != null { .message_status = v }
            }
              v = del(."enrichment@49312"."message.appcat")
              if v != null { .message_appcat = v }
              v = del(."enrichment@49312".status)
              if v != null { .status = v }
              v = del(."enrichment@49312".event_id)
              if v != null { .event_id = v }
              v = del(."enrichment@49312".severity)
              if v != null { .severity = v }
              .processed_by = "observability-pipelines"
              .processed_at = now()

            EOF
          }
        }
        display_name = "Extract enrichment fields to top level"
        enabled      = true
        id           = "processor-extract-sd-fields"
        include      = "*"
      }
    }
    processor_group {
      display_name = "Enrichment"
      enabled      = true
      id           = "processor-group-enrichment-01"
      include      = "*"
      inputs       = ["processor-group-extract-sd-01"]
      processor {
        display_name = "Threat Intel (Snowflake)"
        enabled      = true
        enrichment_table {
          reference_table {
            app_key_key = "PROCESSOR_ENRICHMENT_TABLES_APP_KEY"
            key_field   = "ip_address"
            table_id    = "c14d9be9-f183-4363-88e1-84184090681d"
          }
          target = "threat_intel"
        }
        id      = "processor-enrichment-threat-intel"
        include = "*"
      }
      processor {
        display_name = "ServiceNow CMDB"
        enabled      = true
        enrichment_table {
          reference_table {
            app_key_key = "PROCESSOR_ENRICHMENT_TABLES_APP_KEY"
            key_field   = "ip_address"
            table_id    = "1263c8eb-5818-404a-b246-c71dcd1e9c64"
          }
          target = "servicenow"
        }
        id      = "processor-enrichment-servicenow"
        include = "*"
      }
      processor {
        display_name = "Salesforce"
        enabled      = true
        enrichment_table {
          reference_table {
            app_key_key = "PROCESSOR_ENRICHMENT_TABLES_APP_KEY"
            key_field   = "accountnumber"
            table_id    = "9ef8a76c-cbe8-4773-87fe-2fb23fad432b"
          }
          target = "salesforce"
        }
        id      = "processor-enrichment-salesforce"
        include = "*"
      }
      processor {
        display_name = "Databricks Jobs"
        enabled      = true
        enrichment_table {
          reference_table {
            app_key_key = "PROCESSOR_ENRICHMENT_TABLES_APP_KEY"
            key_field   = "job_id"
            table_id    = "3432c37f-0472-4dc3-b821-21fe287c1eb4"
          }
          target = "databricks"
        }
        id      = "processor-enrichment-databricks"
        include = "*"
      }
      processor {
        display_name = "S3 Asset Inventory"
        enabled      = true
        enrichment_table {
          reference_table {
            app_key_key = "PROCESSOR_ENRICHMENT_TABLES_APP_KEY"
            key_field   = "asset_id"
            table_id    = "27f1df60-b76d-4f0c-9faa-2c57b03b3454"
          }
          target = "s3_asset"
        }
        id      = "processor-enrichment-s3"
        include = "*"
      }
    }
    processor_group {
      display_name = "MITRE ATT&CK FortiGate Enrichment"
      enabled      = true
      id           = "processor-group-69ad4041-b49f-460d-8742-e616b996572e"
      include      = "*"
      inputs       = ["processor-group-enrichment-01"]
      processor {
        add_fields {
          field {
            name  = "source"
            value = "fortigate"
          }
        }
        display_name = "MITRE FortiGate: Add Source"
        enabled      = true
        id           = "processor-0b07080b-cfab-43ab-b1de-6287198c0674"
        include      = "@message_type:(utm OR traffic OR event)"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Initial Access"
          }
          field {
            name  = "mitre.technique"
            value = "Exploit Public-Facing Application"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1190"
          }
        }
        display_name = "MITRE FortiGate: Exploit Attempts - T1190"
        enabled      = true
        id           = "processor-9e0eac8d-adf0-440a-b7e9-d27631423cdb"
        include      = "source:fortigate AND @message_type:utm AND @message_subtype:ips"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Command and Control"
          }
          field {
            name  = "mitre.technique"
            value = "Application Layer Protocol"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1071"
          }
        }
        display_name = "MITRE FortiGate: C2 Traffic - T1071"
        enabled      = true
        id           = "processor-14c2de24-27bb-4fe5-a319-1de063ce444f"
        include      = "source:fortigate AND @message_type:utm AND @message_subtype:app-ctrl AND @message_action:block AND @message_appcat:Botnet"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Command and Control"
          }
          field {
            name  = "mitre.technique"
            value = "Ingress Tool Transfer"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1105"
          }
        }
        display_name = "MITRE FortiGate: Malware Transfers - T1105"
        enabled      = true
        id           = "processor-daa38a76-f65b-43db-a408-f5a4aa4ddbe0"
        include      = "source:fortigate AND @message_type:utm AND @message_subtype:virus"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Exfiltration"
          }
          field {
            name  = "mitre.technique"
            value = "Exfiltration Over C2 Channel"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1041"
          }
        }
        display_name = "MITRE FortiGate: Data Loss - T1041"
        enabled      = true
        id           = "processor-393296c3-9a08-4621-ba4f-c9ef7b954312"
        include      = "source:fortigate AND @message_type:utm AND @message_subtype:dlp"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Impact"
          }
          field {
            name  = "mitre.technique"
            value = "Network Denial of Service"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1498"
          }
        }
        display_name = "MITRE FortiGate: Network DoS - T1498"
        enabled      = true
        id           = "processor-66f59aed-9f29-4cd8-8651-7513d611e02e"
        include      = "source:fortigate AND @message_type:utm AND @message_subtype:anomaly"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Initial Access"
          }
          field {
            name  = "mitre.technique"
            value = "External Remote Services"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1133"
          }
        }
        display_name = "MITRE FortiGate: VPN Access - T1133"
        enabled      = true
        id           = "processor-5494262e-652e-4612-b85a-a35f25d5c8f0"
        include      = "source:fortigate AND @message_type:event AND @message_subtype:vpn AND @message_action:tunnel-up"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Credential Access"
          }
          field {
            name  = "mitre.technique"
            value = "Brute Force: Password Guessing"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1110.001"
          }
        }
        display_name = "MITRE FortiGate: Admin Brute Force - T1110.001"
        enabled      = true
        id           = "processor-a1b20328-dc2a-4460-a8fc-f1c1aad2461b"
        include      = "source:fortigate AND @message_type:event AND @message_subtype:system AND @message_action:login AND @message_status:failed"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Initial Access"
          }
          field {
            name  = "mitre.technique"
            value = "Valid Accounts"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1078"
          }
        }
        display_name = "MITRE FortiGate: Admin Logins - T1078"
        enabled      = true
        id           = "processor-6cc79e56-4025-4135-bed9-7907e7bd27f5"
        include      = "source:fortigate AND @message_type:event AND @message_subtype:system AND @message_action:login AND @message_status:success"
      }
      processor {
        add_fields {
          field {
            name  = "security"
            value = "true"
          }
        }
        display_name = "MITRE FortiGate: Tag Enriched Events"
        enabled      = true
        id           = "processor-179aa750-82e5-4bf2-9fa3-2522efb18a29"
        include      = "source:fortigate AND @mitre.tactic:*"
      }
    }
    processor_group {
      display_name = "MITRE ATT&CK Palo Alto Enrichment"
      enabled      = true
      id           = "processor-group-6564fc49-5261-4fd5-8941-f4fed5d8380c"
      include      = "*"
      inputs       = ["processor-group-69ad4041-b49f-460d-8742-e616b996572e"]
      processor {
        add_fields {
          field {
            name  = "source"
            value = "palo-alto"
          }
        }
        display_name = "MITRE Palo Alto: Add Source"
        enabled      = true
        id           = "processor-9edfabec-66ec-4c3f-8950-181eb19bb17e"
        include      = "@log_type:*"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Initial Access"
          }
          field {
            name  = "mitre.technique"
            value = "Exploit Public-Facing Application"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1190"
          }
        }
        display_name = "MITRE Palo Alto: Exploit Attempts - T1190"
        enabled      = true
        id           = "processor-3ea9eed7-6364-4c55-b179-0054c5a3c2ca"
        include      = "source:palo-alto AND @log_type:THREAT AND @subtype:vulnerability"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Command and Control"
          }
          field {
            name  = "mitre.technique"
            value = "Application Layer Protocol"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1071"
          }
        }
        display_name = "MITRE Palo Alto: C2 Traffic - T1071"
        enabled      = true
        id           = "processor-5901ce97-5708-44f0-a385-3f2071988f66"
        include      = "source:palo-alto AND @log_type:THREAT AND @subtype:spyware"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Command and Control"
          }
          field {
            name  = "mitre.technique"
            value = "Ingress Tool Transfer"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1105"
          }
        }
        display_name = "MITRE Palo Alto: Malware Transfers - T1105"
        enabled      = true
        id           = "processor-438d583b-4545-42f2-9f1b-886149be35c5"
        include      = "source:palo-alto AND @log_type:THREAT AND @subtype:(wildfire OR wildfire-virus OR virus)"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Impact"
          }
          field {
            name  = "mitre.technique"
            value = "Network Denial of Service"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1498"
          }
        }
        display_name = "MITRE Palo Alto: Network DoS - T1498"
        enabled      = true
        id           = "processor-0eeb8c05-9a1d-48ff-9035-4efb9102b6ab"
        include      = "source:palo-alto AND @log_type:THREAT AND @subtype:flood"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Initial Access"
          }
          field {
            name  = "mitre.technique"
            value = "External Remote Services"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1133"
          }
        }
        display_name = "MITRE Palo Alto: GlobalProtect VPN - T1133"
        enabled      = true
        id           = "processor-0aff39c2-44c6-4628-bf87-061a8b81fcb7"
        include      = "source:palo-alto AND @log_type:GLOBALPROTECT AND @status:success AND @event_id:(gateway-connected OR portal-connected)"
      }
      processor {
        add_fields {
          field {
            name  = "mitre.tactic"
            value = "Credential Access"
          }
          field {
            name  = "mitre.technique"
            value = "Brute Force: Password Guessing"
          }
          field {
            name  = "mitre.technique_id"
            value = "T1110.001"
          }
        }
        display_name = "MITRE Palo Alto: Admin Brute Force - T1110.001"
        enabled      = true
        id           = "processor-1d52b8e6-9510-42b7-9bc2-c10d3486c2ba"
        include      = "source:palo-alto AND @log_type:SYSTEM AND @event_id:auth-fail"
      }
      processor {
        add_fields {
          field {
            name  = "security"
            value = "true"
          }
        }
        display_name = "MITRE Palo Alto: Tag Enriched Events"
        enabled      = true
        id           = "processor-09a89e3d-8034-4d7e-b03d-ea570703b54f"
        include      = "source:palo-alto AND @mitre.tactic:*"
      }
    }
    processor_group {
      display_name = "PII Redaction"
      enabled      = true
      id           = "processor-group-pii-redaction"
      include      = "*"
      inputs       = ["processor-group-6564fc49-5261-4fd5-8941-f4fed5d8380c"]
      processor {
        custom_processor {
          remap {
            drop_on_error = false
            enabled       = true
            include       = "*"
            name          = "Redact email addresses"
            source        = <<-EOF
            if exists(.message) && is_string(.message) {
              .message = replace(.message, r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', "[REDACTED_EMAIL]")
            }
            EOF
          }
        }
        display_name = "Redact Email Addresses"
        enabled      = true
        id           = "processor-redact-email"
        include      = "*"
      }
      processor {
        custom_processor {
          remap {
            drop_on_error = false
            enabled       = true
            include       = "*"
            name          = "Redact IP addresses in message body"
            source        = <<-EOF
            if exists(.message) && is_string(.message) {
              .message = replace(.message, r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', "[REDACTED_IP]")
            }
            EOF
          }
        }
        display_name = "Redact IP Addresses in Message"
        enabled      = true
        id           = "processor-redact-ip"
        include      = "*"
      }
    }
    source {
      id = "source-syslog-01"
      rsyslog {
        mode = "tcp"
      }
    }
    use_legacy_search_syntax = false
  }
  name = "Syslog Terraform Demo"
}

output "pipeline_id" {
  value = datadog_observability_pipeline.syslog_demo.id
}
