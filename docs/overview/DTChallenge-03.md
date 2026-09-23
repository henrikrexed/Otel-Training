#  Improve your Dynatrace Setup

[< Previous Challenge](./DTChallenge-02.md) - **[Home](../index.md)** - [Bonus Challenge >](./DTChallenge-04.md)

## Introduction

Now that we have learned how Copilot can help us improve instrumentation its time to improve our Dynatrace setup. There are multiple different things we can do: I am sure you already have your own best practices such as setting up Synthetic Tests for every key Web API, creating customized dashboards, setting up SLOs or creating a Workflow that alerts on problems

## Description

In this challenge you will learn how use CoPilot to improve your Dynatrace setup by implementing Dynatrace Best Practices

- **Shall we setup a Synthetic Test**: Can Copilot help you create a synthetic test against your app?

- **A custom dashboard**: Can Copilot help you create a customized dashboard for your app?

- **A problem workflow**: Can Copilot setup alerting on a e.g: performance or failure rate problems and trigger a workflow that sends you a notification?

- **Extend your Agent**: Whatever use case(s) you implement: can you put all of this into a dynatrace best practice agent?

!!! important "Configuration API Token Required"
    This challenge requires a **Configuration API token** to interact with Dynatrace's Configuration API for creating synthetic tests, dashboards, and workflows.
    
    **Token Variable:** `DYNATRACE_CONFIG_API_TOKEN`
    
    This token should be added as a **secret** in your Codespace settings. You can find the token value in the **launcher** (Dynatrace Launch Pad) under Step 5: Configure Codespace Secrets.
    
    The token has the following scopes:
    
    - ✅ Read settings
    - ✅ Write settings
    - ✅ Read synthetic monitor execution results
    - ✅ Read synthetic locations
    - ✅ Create and read synthetic monitors, locations, and nodes
    - ✅ Read synthetic monitors, locations, and nodes

## Success Criteria
You will have successfully completed this challenge when you:

- Used CoPilot to improve the configuration of Dynatrace
- Created your own custom dyntrace best practices agent

## Learning Resources
- [Dynatrace Synthetics for SRE and DevOps](https://www.youtube.com/watch?v=OhmLEb1R8y4)
