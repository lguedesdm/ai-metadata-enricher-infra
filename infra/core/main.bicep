// =============================================================================
// Core Infrastructure Module
// =============================================================================
// Purpose: Resource group, naming conventions, location, and tagging standards
// for the AI Metadata Enricher platform.
//
// This module establishes the foundation for all other resources.
// =============================================================================

@description('The environment name (dev, test, prod)')
param environment string = 'dev'

@description('The Azure region for resource deployment')
param location string = resourceGroup().location

@description('The base name for the project')
param projectName string = 'ai-metadata-enricher'

@description('Tags to apply to all resources')
param tags object = {
  environment: environment
  project: projectName
  managedBy: 'bicep'
}

// =============================================================================
// OUTPUTS
// =============================================================================
// These outputs provide standardized naming and configuration for downstream modules

@description('Standardized resource name prefix')
output resourcePrefix string = '${projectName}-${environment}'

@description('The location for all resources')
output resourceLocation string = location

@description('Standard tags for all resources')
output resourceTags object = tags

@description('The environment name')
output environmentName string = environment

@description('The project name')
output projectIdentifier string = projectName
