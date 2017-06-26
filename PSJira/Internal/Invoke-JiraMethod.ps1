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
    [uint64]$actualPageSize = 50 #this is the default page size for all Atlassian web services.  i.e. if no paging parameters are specified on the URI, this is what we'd get
    if ($PSCmdlet.PagingParameters.Skip) 
    {
        $Query['startAt'] = $PSCmdlet.PagingParameters.Skip
    }
    if ($PSCmdlet.PagingParameters.First -and ($PSCmdlet.PagingParameters.First  -ne [uint64]::MaxValue)) #if paging is not specified, continue with default behaviour (i.e. page size of 50) to ensure this is not a breaking change
    {
        if ($PSCmdlet.PagingParameters.First -gt 1000) #Limit of the web API https://confluence.atlassian.com/jirakb/changing-maxresults-parameter-for-jira-rest-api-779160706.html
        {
            #for now, if limit exceeded throw exception
            #in future version, consider having function call itself N times to have this function satisfy the page size requirement whilst following the hard limit for the web api
            throw (New-Object -TypeName 'ArgumentException' -ArgumentList "The Atlassian API page size has a hard limit of 1000.  You specified $($PSCmdlet.PagingParameters.First).")
        }
        $Query['maxResults'] = $PSCmdlet.PagingParameters.First
        $actualPageSize = $PSCmdlet.PagingParameters.First
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

                #region "Paging Total"
                If ($PSCmdlet.PagingParameters.IncludeTotalCount) {
                    if ($result.psobject.Properties['startAt'] -and $result.psobject.Properties['maxResults'] -and $result.psobject.Properties['total'])
                    {
                        #if we have a paging total we can use it.  This if checks for the related paging fields to make sure the `total` returned is the paging one / not some property of another object from a method which does not support paging.  https://docs.atlassian.com/jira/REST/cloud/
                        $PSCmdlet.PagingParameters.NewTotalCount($result.total, 1.0)
                    }
                    else
                    {
                        #if our root object doesn't contain paging properties, assume that the root is an array of actual results
                        if ($actualPageSize -gt $result.Count) 
                        {
                            $PSCmdlet.PagingParameters.NewTotalCount($result.Count + ($PSCmdlet.PagingParameters.Skip), 1.0)
                        }
                        else
                        {
                            $PSCmdlet.PagingParameters.NewTotalCount($result.Count + ($PSCmdlet.PagingParameters.Skip) + 1, 0.01) #we know we've got at least (Count + Skip) results; so better than 0 probability on this estimate; but nowhere near 1.0.  Added 1 to this estimate so that it's clear that the user request more data (i.e. there's always at least 1 more record to get until we get the real figure)
                            #have asked for advice on how estimates should work (amongst other things) here: https://codereview.stackexchange.com/questions/164252/powershell-supports-paging
                        }
                    }
                }
                #end region "Paging Total"
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
