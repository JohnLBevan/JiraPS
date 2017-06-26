
# Dot source this script in any Pester test script that requires the module to be imported.

$ModuleName = 'PSJira'
$ModuleManifestPath = "$PSScriptRoot\..\$ModuleName\$ModuleManifestName.psd1"
$RootModule = "$PSScriptRoot\..\$ModuleName\$ModuleName.psm1"

# The first time this is called, the module will be forcibly (re-)imported.
# After importing it once, the $SuppressImportModule flag should prevent
# the module from being imported again for each test file.

if (-not (Get-Module -Name $ModuleName -ErrorAction SilentlyContinue) -or (!$SuppressImportModule)) {
    # If we import the .psd1 file, Pester has issues where it detects multiple
    # modules named PSJira. Importing the .psm1 file seems to correct this.

    # -Scope Global is needed when running tests from within a CI environment
    Import-Module $RootModule -Scope Global -Force

    # Set to true so we don't need to import it again for the next test
    $SuppressImportModule = $true
}

[System.Diagnostics.CodeAnalysis.SuppressMessage('PSUseDeclaredVarsMoreThanAssigments', '', Scope = '*', Target = 'ShowMockData')]
$ShowMockData = $false

[System.Diagnostics.CodeAnalysis.SuppressMessage('PSUseDeclaredVarsMoreThanAssigments', '', Scope = '*', Target = 'ShowDebugText')]
$ShowDebugText = $false

function defProp($obj, $propName, $propValue) {
    It "Defines the '$propName' property" {
        $obj.$propName | Should Be $propValue
    }
}

function hasProp($obj, $propName) {
    It "Defines the '$propName' property" {
        $obj | Get-Member -MemberType *Property -Name $propName | Should Not BeNullOrEmpty
    }
}

function hasNotProp($obj, $propName) {
    It "Defines the '$propName' property" {
        $obj | Get-Member -MemberType *Property -Name $propName | Should BeNullOrEmpty
    }
}

function defParam($command, $name) {
    It "Has a -$name parameter" {
        $command.Parameters.Item($name) | Should Not BeNullOrEmpty
    }
}

# This function must be used from within an It block
function checkType($obj, $typeName) {
    if ($obj -is [System.Array]) {
        $o = $obj[0]
    }
    else {
        $o = $obj
    }

    $o.PSObject.TypeNames[0] | Should Be $typeName
}

function castsToString($obj) {
    if ($obj -is [System.Array]) {
        $o = $obj[0]
    }
    else {
        $o = $obj
    }

    $o.ToString() | Should Not BeNullOrEmpty
}

function checkPsType($obj, $typeName) {
    It "Uses output type of '$typeName'" {
        checkType $obj $typeName
    }
    It "Can cast to string" {
        castsToString($obj)
    }
}

function ShowMockInfo($functionName, [String[]] $params) {
    if ($ShowMockData) {
        Write-Host "       Mocked $functionName" -ForegroundColor Cyan
        foreach ($p in $params) {
            Write-Host "         [$p]  $(Get-Variable -Name $p -ValueOnly)" -ForegroundColor Cyan
        }
    }
}

#compares 2 URIs are identical, but doesn't care about querystring parameter order
function CompareUri ($GivenUri, $ShouldBeUri) {
    $uriComponentsOptions = ([UriComponents]::AbsoluteUri)
    $uriFormatOptions = ([UriFormat]::SafeUnescaped)
    $stringComparisonOptions = ([StringComparison]::OrdinalIgnoreCase)
    $a = OrderUriQueryString($GivenUri)
    $b = OrderUriQueryString($ShouldBeUri)
    [Uri]::Compare($a, $b, $uriComponentsOptions, $uriFormatOptions, $stringComparisonOptions)
}

function OrderUriQueryString($Uri) {
    [System.UriBuilder]$UriBuilder = New-Object -TypeName 'System.UriBuilder' -ArgumentList $Uri
    [System.Collections.Specialized.NameValueCollection]$Query = [System.Web.HttpUtility]::ParseQueryString($UriBuilder.Query)
    [System.Collections.Specialized.NameValueCollection]$Query2 = [System.Web.HttpUtility]::ParseQueryString('') #we have to initialise this way as HttpValueCollection has no public constructor (https://referencesource.microsoft.com/#system.web/HttpValueCollection.cs,fde6b9ec5f1ed58a,references)  
    $Query.AllKeys | sort | %{ $Query2.Add($_, $Query[$_]) }
    $UriBuilder.Query = $Query2.ToString()
    $UriBuilder.ToString()
}

#Append paging parameters to any URLs used in testing; saves us having to code those values in for each test.
function AppendPaging($Uri, [uint64]$startAt = 0, [uint64]$maxResults = [uint64]::MaxValue) {
    [System.UriBuilder]$UriBuilder = New-Object -TypeName 'System.UriBuilder' -ArgumentList $Uri
    [System.Collections.Specialized.NameValueCollection]$Query = [System.Web.HttpUtility]::ParseQueryString($UriBuilder.Query) 
    if ($startAt) 
    {
        $Query['startAt'] = $startAt
    }
    if ($maxResults -and ($maxResults -ne [uint64]::MaxValue)) 
    {
        $Query['maxResults'] = $maxResults
    }
    $UriBuilder.Query = $Query.ToString()
    $UriBuilder.ToString()
}

if ($ShowDebugText) {
    Mock "Write-Debug" {
        Write-Host "       [DEBUG] $Message" -ForegroundColor Yellow
    }
}
