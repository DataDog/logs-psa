# Everything here-in serves as an example of how to use Observability Pipelines
# in the Datadog Terraform provider and is not meant to be used as-is in production.
terraform {
  required_providers {
    datadog = {
      source = "DataDog/datadog"
    }
  }
}

variable "datadog_api_key" {
  type        = string
  description = "Datadog API Key"
}

variable "datadog_app_key" {
  type        = string
  description = "Datadog Application Key"
}

# Configure the Datadog provider
provider "datadog" {
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
}

# Define the Observability Pipeline resource
# https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline
resource "datadog_observability_pipeline" "example-pipeline" {
  name = "My OP Pipeline Example"

  config {
    #=========================================================================
    # SOURCE
    #=========================================================================
    # Set Datadog Agent as our source of logs
    # https://docs.datadoghq.com/observability_pipelines/sources/datadog_agent/?tab=agentconfigurationfile
    # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nestedblock--config--source--datadog_agent
    source {
      id = "source-dd-agent"
      datadog_agent {}
    }

    #=========================================================================
    # First path (split pipeline)
    #=========================================================================
    #
    # NOTE: Provider schema changed:
    # Processors are now ordered explicitly inside a processor group, and only
    # processor_group has `inputs` (not individual processors).
    processor_group {
      id      = "group-datadog-logs"
      inputs  = ["source-dd-agent"]
      include = "*"
      enabled = true

      # Add a field so we can identify the logs that were sent via this pipeline
      # https://docs.datadoghq.com/observability_pipelines/processors/edit_fields
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessoradd_fields
      processor {
        id      = "add-field-sent-from-op"
        include = "*"
        enabled = true

        add_fields {
          field {
            name  = "sent_via_op"
            value = "true"
          }
        }
      }

      # Perform out-of-the-box parsing of haproxy and custom processing for my-service logs
      # This will give us attributes from unstructured on which we can perform additional processing
      # It is recommended to target grok with specific filters as it can be compute intensive
      # https://docs.datadoghq.com/observability_pipelines/processors/grok_parser/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessorparse_grok
      processor {
        id                    = "grok-processor-dd-logs"
        include               = "(source:haproxy-ingress OR service:my-service)"
        enabled               = true

        parse_grok {
          disable_library_rules = false
          rule {
            source = "my-service"

            match_rule {
              name = "rule1"
              rule = "%%{date(\"yyyy-MM-dd HH:mm:ss.SSS\"):syslog.timestamp}\\:\\s+%%{notSpace:logger.name}\\s+%%{word:level}\\s+-%%{data:message}"
            }
            match_rule {
              name = "rule2"
              rule = "\\[%%{word:level}\\]\\s+\\[%%{date(\"MM/dd/yyyy HH:mm:ss.SSS\"):syslog.timestamp}\\]\\s+\\[%%{notSpace:logger.thread_name}\\]\\s+%%{data:message}"
            }
          }
        }
      }

      # Generate metrics from logs that we can then discard saving on ingest costs
      # These are just examples, please modify for your real use cases
      # Note how we can define multiple metrics in a single generate_datadog_metrics processor
      # to reduce the number of processors we need to define
      # https://docs.datadoghq.com/observability_pipelines/processors/generate_metrics/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessorgenerate_datadog_metrics
      processor {
        id      = "log2metrics"
        include = "*"
        enabled = true

        generate_datadog_metrics {
          metric {
            group_by    = ["account_id"]
            include     = "service:my-service \"Retrieving extra rewards\""
            metric_type = "count"
            name        = "my_service.extra_rewards_count"
            value {
              field    = null
              strategy = "increment_by_one"
            }
          }

          metric {
            group_by    = ["backend_name", "http_path", "method"]
            include     = "service:haproxy-ingress status:ok"
            metric_type = "count"
            name        = "ha_proxy_ingress.ok"
            value {
              field    = null
              strategy = "increment_by_one"
            }
          }
        }
      }

      # Filter out noisy and extraneous logs that we don't need to ingest
      # These are just examples, please modify for your real use cases
      # Note how we can define multiple filter queries in a single filter processor
      # to reduce the number of processors we need to define
      # https://docs.datadoghq.com/observability_pipelines/processors/filter/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessorfilter
      processor {
        id      = "filter-noisy-extraneous-logs"
        include = "NOT ((service:my-service \"Retrieving extra rewards\") OR (service:haproxy-ingress status:ok))"
        enabled = true

        filter {}
      }

      # Sample noisy logs to reduce volume that you may not need 100% visibility on
      # This is just an example, please modify for your real use cases
      # https://docs.datadoghq.com/observability_pipelines/processors/sample
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessorsample
      processor {
        id         = "sample-noisy-logs"
        include    = "(service:my-service status:info \"operation retrieverewards\") OR (service:haproxy-ingress status:info)"
        enabled    = true

        sample {
          percentage = 50
        }
      }

      # Deduplicate logs that are similar to reduce noise, here we are acting on just the message field
      # The dedupe processor caches the last 5,000 messages and compares new messages against them
      # It can be compute intensive, so it is recommended to target it to specific
      # filters where you know there will be a lot of similar logs
      # https://docs.datadoghq.com/observability_pipelines/processors/dedupe/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nestedblock--config--processor_group--processor--dedupe
      processor {
        id      = "dedupe-like-logs"
        include = "(service:my-service OR service:haproxy-ingress) (status:info OR status:ok)"
        enabled = true

        dedupe {
          fields = ["message"]
          mode   = "match"
        }
      }

      # An example of enforcing quotas on logs to prevent excessive ingestion
      # This is just an example, please modify for your real use cases
      # Note how we can define multiple overrides for different values of the partition field
      # to reduce the number of processors we need to define
      # https://docs.datadoghq.com/observability_pipelines/processors/quota/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nestedblock--config--processor_group--processor--quota
      processor {
        id                             = "service-quota"
        include                        = "*"
        enabled                        = true

        quota {
          drop_events                    = true
          ignore_when_missing_partitions = true
          name                           = "servicequota"
          overflow_action                = null
          partition_fields               = ["service"]

          limit {
            enforce = "events"
            limit   = 50000000
          }

          override {
            field {
              name  = "service"
              value = "my-service"
            }
            limit {
              enforce = "events"
              limit   = 400000000
            }
          }

          override {
            field {
              name  = "service"
              value = "haproxy-ingress"
            }
            limit {
              enforce = "events"
              limit   = 500000000
            }
          }
        }
      }

      # An example of throttling logs to prevent excessive ingestion from spikes
      # https://docs.datadoghq.com/observability_pipelines/processors/throttle
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nestedblock--config--processor_group--processor--throttle
      processor {
        id        = "service-throttle"
        include   = "*"
        enabled   = true

        throttle {
          group_by  = ["service"]
          threshold = 2000000
          window    = 300
        }
      }
    }

    #=========================================================================
    # Second path (split pipeline)
    #=========================================================================
    # A second processor group to send the same logs to a different destination
    # with different processing needs, in this case Google Cloud Storage. Note
    # how we are reusing the same source but defining different processing
    processor_group {
      id      = "group-gcs"
      inputs  = ["source-dd-agent"]
      include = "*"
      enabled = true

      # Add a field so we can identify the logs that were sent via this pipeline
      # https://docs.datadoghq.com/observability_pipelines/processors/edit_fields
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nestedblock--config--processors--add_fields
      processor {
        id      = "add-field-sent-from-op-gcs"
        include = "*"
        enabled = true

        add_fields {
          field {
            name  = "sent_via_op"
            value = "true"
          }
        }
      }

      # This is a duplicate of the grok processor above, but it is targeting a different
      # destination, in this case Google Cloud Storage. This ensures that the logs
      # are parsed before being sent to the destination, for easy rehydration.
      # https://docs.datadoghq.com/observability_pipelines/processors/grok_parser/
      # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configprocessor_groupprocessorparse_grok
      processor {
        id                    = "grok-processor-gcs"
        include               = "(source:haproxy-ingress OR service:my-service)"
        enabled               = true

        parse_grok {
          disable_library_rules = false

          rule {
            source = "my-service"

            match_rule {
              name = "rule1"
              rule = "%%{date(\"yyyy-MM-dd HH:mm:ss.SSS\"):syslog.timestamp}\\:\\s+%%{notSpace:logger.name}\\s+%%{word:level}\\s+-%%{data:message}"
            }
            match_rule {
              name = "rule2"
              rule = "\\[%%{word:level}\\]\\s+\\[%%{date(\"MM/dd/yyyy HH:mm:ss.SSS\"):syslog.timestamp}\\]\\s+\\[%%{notSpace:logger.thread_name}\\]\\s+%%{data:message}"
            }
          }
        }
      }
    }

    #=========================================================================
    # DESTINATIONS
    #=========================================================================
    # Set Datadog Logs as our first destination
    # https://docs.datadoghq.com/observability_pipelines/destinations/datadog_logs/
    # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configdestinationdatadog_logs
    destination {
      id     = "destination-datadog-logs"
      inputs = ["group-datadog-logs"]

      datadog_logs {}
    }

    # Set Google Cloud Storage as our second destination
    # https://docs.datadoghq.com/observability_pipelines/destinations/google_cloud_storage/
    # https://registry.terraform.io/providers/DataDog/datadog/latest/docs/resources/observability_pipeline#nested-schema-for-configdestinationgoogle_cloud_storage
    destination {
      id            = "destination-gcs"
      inputs        = ["group-gcs"]

      google_cloud_storage {
        acl           = "authenticated-read"
        bucket        = "log-archive"
        key_prefix    = "op-logs"
        storage_class = "STANDARD"

        auth {
          credentials_file = "/credentials.json"
        }
      }
    }
  }
}
