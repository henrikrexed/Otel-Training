#  Prompt your observability data

[< Previous Challenge](./DTChallenge-00.md) - **[Home](../index.md)** - [Next Challenge >](./DTChallenge-02.md)

## Introduction

Before we improve any instrumentation its time to analyze the logs, metrics, spans, events we ingest right now into Dynatrace. While we can open the Kubernetes, Logs, Distributed Traces or Sevices App on our tenant our goal is to learn how to use CoPilot in our IDE to access our data.

In this challenge we will learn how to prompt but also how to define our own instructions, rules and agents to make sure we are querying the correct data. Because remember: All hackathon participants run their own Kubernetes cluster in their codespace and all of them are monitored by the same Dynatrace tenant.

Everyone of you must find the best way to instruct copilot to only query the data that comes from your code space

**HINT:** Your Kubernetes Cluster has a unique name - its the name of your code space. That name is also the name that Dynatraace has and therefore we can use it to filter on the right data if we instruct our copilot correctly!

## Description

In this challenge you will learn how create proper prompts or how to create your own agent that knows how to only query the data from Dynatrace that is ingested from your specific Kubernetes cluster.

- **Start General, Then Get Specific**: Start prompting for logs, then figure out how to rephrase your prompts to filter on your own data

- **Create your own observability agent**: Take your lessons learned and create your own agent that you can then easily use to query the relevant data

- **Go beyond logs**: Use and refine your agent to query information from your spans, metrics and your kubernetes workloads!

## Success Criteria
You will have successfully completed this challenge when you:

- Demonstrated how you can prompt for observability data that belongs to your kubernetes cluster
- Created your own observability agent that helps you analyze your logs, metrics, spans and workloads

## Learning Resources
- [Dynatrace MCP Prompt Examples](https://github.com/dynatrace-oss/dt-mcp-playground)
