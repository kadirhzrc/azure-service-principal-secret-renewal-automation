<#
    .SYNOPSIS
    Handles secret rotation of a specific application.
    .DESCRIPTION
    Creates new client secret, updates the service connection, deletes the older secret(s).
    .INPUTS
    None. You cannot pipe objects to the script.
    .OUTPUTS
    None. The script does not generate any output.
#>

# Set paramaters
$applicationId = $env:APP_ID
$projectUri = $env:PROJECT_URI
# Length of secret validity
$SecretAddedDays = $env:DURATION


# Get access token for MS Graph API
$token = Get-AzAccessToken -ResourceTypeName MSGraph

# Azure Portal header for endpoint call
$headersGraph = @{
    "Content-Type"  = "application/json"
    "Authorization" = "$($token.Type) $($token.Token)"
}

# Azure DevOps header for endpoint call
$headerDevOps = @{
    "Authorization" = "Bearer $env:SYSTEM_ACCESSTOKEN" # Access token for built-in Build Service user
    "Content-Type"  = "application/json"
}

# Retrieve application & related information
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($applicationId)'"
    "Headers" = $headersGraph
}
$applications = Invoke-RestMethod @params -UseBasicParsing

$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($applications.value[0].id)"
    "Headers" = $headersGraph
}
$application = Invoke-RestMethod @params -UseBasicParsing
Write-Host "Found application with id '$($application.id)', appId '$($application.appId)' and displayName '$($application.displayName)'"

# Retrieve Service Connection & related information
$params = @{
    "Method"  = "Get"
    "Uri"     = "$($projectUri)/_apis/serviceendpoint/endpoints?api-version=6.1-preview"
    "Headers" = $headerDevOps
}
$serviceConnections = Invoke-RestMethod @params -UseBasicParsing
$serviceConnection = $serviceConnections.value | Where-Object -FilterScript { $_.type -eq "azurerm" -and $_.authorization.scheme -eq "ServicePrincipal" -and $_.authorization.parameters.serviceprincipalid -eq $applicationId }

$params = @{
    "Method"  = "Get"
    "Uri"     = "$($projectUri)/_apis/serviceendpoint/endpoints/$($serviceConnection.id)?api-version=6.1-preview"
    "Headers" = $headerDevOps
}
$serviceConnection = Invoke-RestMethod @params -UseBasicParsing
Write-Host "Found Service Connection '$($serviceConnection.name)'"

# Parse secret name in the following format: "{Subscription} {Month} {Day} Pipeline"
$baseName = $serviceConnection.name
$monthName = (Get-Culture).DateTimeFormat.GetAbbreviatedMonthName((Get-Date).Month)
$date = Get-Date
$dayNum = $date.day
$nameSuffix = "Pipeline"
$secretName = $baseName + " " + $monthName + " " + $dayNum + " " + $nameSuffix

# Create new application secret
$body = @{
    "passwordCredential" = @{
        "displayName" = $secretName
        "endDateTime" = [System.DateTime]::UtcNow.AddDays($SecretAddedDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}
Write-Host "Adding new secret with following name & duration of validity:"
Write-Host $body.passwordCredential.displayName
Write-Host $SecretAddedDays.ToString() "days"

$params = @{
    "Method"  = "Post"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($application.id)/addPassword"
    "Headers" = $headersGraph
    "Body"    = $body | ConvertTo-Json -Compress
}
$newPassword = Invoke-RestMethod @params -UseBasicParsing
Write-Host "New secret created with id: $($newPassword.keyId)"

# Update Service Connection with new secret
$serviceConnection.authorization.parameters.servicePrincipalKey = $newPassword.secretText
$serviceConnection.isReady = $false
$params = @{
    "Method"  = "Put"
    "Uri"     = "$($projectUri)/_apis/serviceendpoint/endpoints/$($serviceConnection.id)?api-version=6.1-preview"
    "Headers" = $headerDevOps
    "Body"    = $serviceConnection | ConvertTo-Json -Compress -Depth 99
}
$serviceConnection = Invoke-WebRequest @params -UseBasicParsing
Write-Output "Service Connection updated successfully"

# Delete older secret(s)
# Add "-Skip n" to the end of next line to skip n number of older secrets (sorted by creation date)
$passwordsToRemove = $application.passwordCredentials | Where-Object -FilterScript { $_.keyId -ne $newPassword.keyId } | Sort-Object -Property startDateTime | Select-Object
Write-Host "Found $(@($passwordsToRemove).Count) application secrets to remove"
foreach ($passwordToRemove in $passwordsToRemove) {
    Write-Host "Remove application secret '$($passwordToRemove.keyId)' with start date '$($passwordToRemove.startDateTime)' and end date '$($passwordToRemove.endDateTime)'"
    $body = @{
        "keyId" = $passwordToRemove.keyId
    }
    $params = @{
        "Method"  = "Post"
        "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($application.id)/removePassword"
        "Headers" = $headersGraph
        "Body"    = $body | ConvertTo-Json -Compress
    }
    $removedPassword = Invoke-WebRequest @params -UseBasicParsing
    if ($removedPassword.StatusCode -eq 204) {
        Write-Host "Older secret removed successfully"
    } else {
        Write-Warning "  Failed to remove password with status code $($removedPassword.StatusCode)"
    }
}