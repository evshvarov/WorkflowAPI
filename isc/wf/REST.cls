Class isc.wf.REST Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

Parameter CHARSET = "UTF-8";

Parameter UseSession As Integer = 1;

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
<Route Url="/tasks" Method="GET" Call="getTasks"/>
<Route Url="/tasks/:count" Method="GET" Call="getTasks"/>
<Route Url="/tasks/:count/:maxId" Method="GET" Call="getTasks"/>

<Route Url="/task/:id" Method="GET" Call="getTask"/>
<Route Url="/task/:id" Method="POST" Call="postTask"/>

<Route Url="/test" Method="GET" Call="test"/>
<Route Url="/logout" Method="GET" Call="logout"/>
</Routes>
}

/// End session
ClassMethod logout() As %Status
{
	#dim %session As %CSP.Session
	set st = %session.Logout(1)
	set %session.EndSession = 1
	return st
}

/// Test method
ClassMethod test() As %Status
{
    write "{""Status"": ""OK""}"
    return $$$OK
}

/// Get tasks. Supports pagination.
/// count - number of records to get
/// maxId - latest id, leave empty to start from the begining
/// set sc = ##class(isc.wf.REST).getTasks()
ClassMethod getTasks(count = 100, maxId = "") As %Status
{
	#dim sc As %Status = $$$OK
	#dim isFirst As %Boolean = $$$YES
	&sql(	DECLARE C1 CURSOR FOR
			SELECT TOP :count 
				 %ID,  IsNew,  Task->%Priority, Task->%Subject, Left(Task->%Message,25), TimeCreated,  RoleName
			INTO :id, :isNew, :priority,        :subject,       :message,                :timeCreated, :role
			FROM EnsLib_Workflow.Worklist
			WHERE (UserName = USER) 
				AND ((Task->TaskStatus_AssignedTo IS NULL) OR (Task->TaskStatus_AssignedTo = UserName))
				AND ((%ID < :maxId) OR (:maxId IS NULL))
			ORDER BY %ID DESC)
	&sql(OPEN C1)
	&sql(FETCH C1)
	write:((SQLCODE=0) || (SQLCODE=100)) "["
	while (SQLCODE = 0) {
		if isFirst {
			set isFirst = $$$NO
		} else {
			write ",",!
		}
		write "{""id"":""", id,""",",
		 			"""isNew"":",isNew,",",
		 			"""priority"":",priority,",",
		 			"""subject"":""", $zcvt(subject,"O", "JSON"),""",",
		 			"""message"":""", $zcvt(message,"O", "JSON"),""",",
		 			"""timeCreated"":""", timeCreated,""",",
		 			"""role"":""", role,"""}"
		&sql(FETCH C1)
	}
	if (SQLCODE'=100) {
		set sc = $$$ERROR($$$SQLError, SQLCODE, $g(%msg))
	} else {
		write "]"
	}
	&sql(CLOSE C1)
	
	quit sc
}

/// Get one task
/// set sc = ##class(isc.wf.REST).getTask("318||dev")
ClassMethod getTask(id) As %Status
{
	#dim sc As %Status = $$$OK
	&sql(	SELECT %ID,  IsNew,  Task->%Priority, Task->%Subject, Task->%Message, TimeCreated,  RoleName,  Task,  Task->%Actions, Task->%FormFields
			INTO   :id, :isNew, :priority,        :subject,       :message,       :timeCreated, :role,     :task, :actions,       :formFields
			FROM EnsLib_Workflow.Worklist
			WHERE (%ID = :id) AND (UserName = USER))
	If (SQLCODE = 0) {
		Write "{""id"":""", id,""",",
		 			"""isNew"":",isNew,",",
		 			"""priority"":",priority,",",
		 			"""subject"":""",$zcvt(subject,"O", "JSON"),""",",
		 			"""message"":""",$zcvt(message,"O", "JSON"),""",",
		 			"""timeCreated"":""",timeCreated,""",",
		 			"""role"":""",role,""",",
		 			"""actions"":""",actions,""",",
		 			"""formFields"":{"
		 
		 Merge fieldValues = ^Ens.MessageBodyD(task, "%FormValues")	
		 Set fieldCount = $l(formFields, ",")
		 For field = 1:1:fieldCount {
			 Set fieldName = $p(formFields, ",", field)
			 Set fieldValue = $g(fieldValues(fieldName))
			 Write """",$zcvt(fieldName,"O", "JSON"),""":""",$zcvt(fieldValue,"O", "JSON"),""""
			 Write:(field<fieldCount) ","
		 }
		 Write "}}"
	} Else {
		Set sc = $$$ERROR($$$SQLError, SQLCODE, $g(%msg))
	}
	
	quit sc
}

/// Submit task. Works only in CSP context
/// formFields - pass all field values as json object properties
/// { "action": "action1", "formFields": {}}
ClassMethod postTask(id As %String) As %Status
{
	#dim %request As %CSP.Request
	// For EnsLib.Workflow.FormEngine compatibility
	set %request.Data("$ITEMID",1) = id
	
	set taskResponse = ##class(EnsLib.Workflow.TaskResponse).%OpenId($p(id, "||", 1), , .sc)
	quit:$$$ISERR(sc) sc
	
	set owner = taskResponse.%TaskStatus.AssignedTo
	quit:((owner'=$username) && (owner '="")) $$$ERROR($$$GeneralError, "User " _ $username _ " does not have rights to modify this task")
	
	set %request.Content = {}.%FromJSON(%request.Content)
	set taskResponse.%Action = %request.Content.action
	
	set iterator = %request.Content.formFields.%GetIterator()
	while iterator.%GetNext(.key, .value) {
		set %request.Data(key,1) = value
	}
	
	quit ##class(EnsLib.Workflow.FormEngine).%OnSubmit(taskResponse, .msq)
}

/// Only Workflow users can use this api
ClassMethod OnPreDispatch(pUrl As %String, pMethod As %String, ByRef pContinue As %Boolean) As %Status
{
	Set pContinue = ##class(EnsLib.Workflow.UserDefinition).%ExistsId($username)
    Quit $$$OK
}

/// This method takes a status, renders it as json (if requested) and outputs the result
ClassMethod outputStatus(pSC As %Status) As %Status [ Internal ]
{
    #dim tSC As %Status = $$$OK
    #dim e As %Exception.AbstractException
    
    Try {
        
        #dim tJSON As %ZEN.proxyObject
    
        If ..AcceptsContentType("application/json") {
        
            Set %response.ContentType = ..#CONTENTTYPEJSON
        
            #; Convert the exception to a status and render to JSON
            Set tSC = ..StatusToProxyObject(pSC, .tJSON)
            Set tJSON.stack = ..getDebugInfo()
            If $$$ISERR(tSC) Quit

            #; Write the JSON to the output device
            Set tSC = tJSON.%ToJSON(, "aeloqutwc")
            If $$$ISERR(tSC) Quit
            
        } else {
            
            #; Set plain text
            Set %response.ContentType = ..#CONTENTTYPETEXT
            
            #; Write out a simple text message
            Do ##class(%Exception.StatusException).CreateFromStatus(pSC).OutputToDevice()
        }
        
    } Catch (e) {
        #; Oops
        Set tSC = e.AsStatus()
    }
    Quit $$$OK
}

ClassMethod getDebugInfo() As %ZEN.proxyObject
{
	set obj = ##class(%ZEN.proxyObject).%New()
	set obj.stack = ..getStackInfo()
	set obj.objlasterror = $system.Status.GetErrorText($get(%objlasterror))
	set obj.request = %request
	set obj.response = %response
	set obj.user = $username
	
	return obj
}

ClassMethod getStackInfo() As %ListOfDataTypes
{

	set ex = ##class(%Exception.SystemException).%New()
	do ex.StackAsArray(.stack)
	set list = ##class(%ListOfObjects).%New()
	for i=1:1:stack {
		set obj = ##class(%ZEN.proxyObject).%New()
		set obj.line = stack(i,"PLACE")
		set obj.call =  stack(i)
		set obj.part = $piece($piece(stack(i,"PLACE"), "^", *), " ", 1)
		do list.Insert(obj)
	}
	
	return list
}

}
