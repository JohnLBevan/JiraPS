function Invoke-JiraMethod {
    #Requires -Version 3
    [CmdletBinding(DefaultParameterSetName = 'UseCredential', SupportsPaging = $true)]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put', 'Delete')]
        [String] $Method,

        [Parameter(Mandatory = $true)]
        [String] $Uri,

        [ValidateNotNullOrEmpty()]
        [String] $Body,

        [Parameter(ParameterSetName = 'UseCredential',
            Mandatory = $false)]
        [System.Management.Automation.PSCredential] $Credential

        #        [Parameter(ParameterSetName='UseSession',
        #                   Mandatory = $true)]
        #        [Object] $Session
    )

    # load DefaultParameters for Invoke-WebRequest
    # as the global PSDefaultParameterValues is not used
    # TODO: find out why PSJira doesn't need this
    $PSDefaultParameterValues = $global:PSDefaultParameterValues

    $headers = @{}

    if ($Credential) {
        Write-Debug "[Invoke-JiraMethod] Using HTTP Basic authentication with provided credentials for $($Credential.UserName)"
        [String] $Username = $Credential.UserName
        $token = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Username}:$($Credential.GetNetworkCredential().Password)"))
        $headers.Add('Authorization', "Basic $token")
        Write-Verbose "Using HTTP Basic authentication with username $($Credential.UserName)"
    }
    else {
        Write-Debug "[Invoke-JiraMethod] Credentials were not provided. Checking for a saved session"
        $session = Get-JiraSession
        if ($session) {
            Write-Debug "[Invoke-JiraMethod] A session was found; using saved session (Username=[$($session.Username)], JSessionID=[$($session.JSessionID)])"
            Write-Verbose "Using saved Web session with username $($session.Username)"
        }
        else {
            $session = $null
            Write-Debug "[Invoke-JiraMethod] No saved session was found; using anonymous access"
        }
    }


    [System.UriBuilder]$UriBuilder = New-Object -TypeName 'System.UriBuilder' -ArgumentList $Uri
    [System.Collections.Specialized.NameValueCollection]$Query = [System.Web.HttpUtility]::ParseQueryString($UriBuilder.Query)
 
    #region "Paging"
    if ($PSCmdlet.PagingParameters.Skip) 
    {
        $Query['startAt'] = $PSCmdlet.PagingParameters.Skip
    }
    if ($PSCmdlet.PagingParameters.First) #this will likely always be true since defaults to [uint64]::MaxValue, but potentially a user may pass value 0?
    {
        $Query['maxResults'] = $PSCmdlet.PagingParameters.First
    }
    #endregion "Paging"

    $UriBuilder.Query = $Query.ToString()
    #todo: \remove these before checking in\
    write-verbose "JB >> URI: $URI" -verbose
    write-verbose "JB >> Builder: $($UriBuilder.ToString())" -verbose
    #todo: /remove these before checking in/
    $iwrSplat = @{
        Uri             = ($UriBuilder.ToString())
        Headers         = $headers
        Method          = $Method
        ContentType     = 'application/json; charset=utf-8'
        UseBasicParsing = $true
        ErrorAction     = 'SilentlyContinue'
    }

    if ($Body) {
        # http://stackoverflow.com/questions/15290185/invoke-webrequest-issue-with-special-characters-in-json
        $cleanBody = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $iwrSplat.Add('Body', $cleanBody)
    }

    if ($Session) {
        $iwrSplat.Add('WebSession', $session.WebSession)
    }

    # We don't need to worry about $Credential, because it's part of the headers being sent to Jira

    try {

        Write-Debug "[Invoke-JiraMethod] Invoking JIRA method $Method to URI $URI"
        $webResponse = Invoke-WebRequest @iwrSplat
    } catch {
        # Invoke-WebRequest is hard-coded to throw an exception if the Web request returns a 4xx or 5xx error.
        # This is the best workaround I can find to retrieve the actual results of the request.
        $webResponse = $_.Exception.Response
    }

    if ($webResponse) {
        Write-Debug "[Invoke-JiraMethod] Status code: $($webResponse.StatusCode)"

        if ($webResponse.StatusCode.value__ -gt 399) {
            Write-Warning "JIRA returned HTTP error $($webResponse.StatusCode.value__) - $($webResponse.StatusCode)"

            # Retrieve body of HTTP response - this contains more useful information about exactly why the error
            # occurred
            $readStream = New-Object -TypeName System.IO.StreamReader -ArgumentList ($webResponse.GetResponseStream())
            $responseBody = $readStream.ReadToEnd()
            $readStream.Close()
            Write-Debug "[Invoke-JiraMethod] Retrieved body of HTTP response for more information about the error (`$responseBody)"
            $result = ConvertFrom-Json2 -InputObject $responseBody
        }
        else {
            if ($webResponse.Content) {
                Write-Debug "[Invoke-JiraMethod] Converting body of response from JSON"
                $result = ConvertFrom-Json2 -InputObject $webResponse.Content
            }
            else {
                Write-Debug "[Invoke-JiraMethod] No content was returned from JIRA."
            }
        }

        if (Get-Member -Name "Errors" -InputObject $result -ErrorAction SilentlyContinue) {
            Write-Debug "[Invoke-JiraMethod] An error response was received from JIRA; resolving"
            Resolve-JiraError $result -WriteError
        }
        else {
            Write-Debug "[Invoke-JiraMethod] Outputting results from JIRA"
            Write-Output $result
        }
    }
    else {
        Write-Debug "[Invoke-JiraMethod] No Web result object was returned from JIRA. This is unusual!"
    }
}
