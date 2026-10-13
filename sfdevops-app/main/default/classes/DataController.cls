/**
 * Records-not-metadata deployment for cdoDataDeployer: data sets, their templates (one object's
 * extraction rule each) and relationships, and the deploy, which sends the plan to
 * sf-data-deploy.yml as base64 JSON (CONTRACTS.md section 5).
 */
public with sharing class DataController {

    @AuraEnabled(cacheable=true)
    public static List<CDO_Data_Set__c> getDataSets() {
        return [
            SELECT Id, Name, Description__c, Status__c, Project__c, Project__r.Name,
                   Source_Environment__c, Source_Environment__r.Name, Source_Environment__r.Pipeline_Key__c,
                   Target_Environment__c, Target_Environment__r.Name, Target_Environment__r.Pipeline_Key__c,
                   Last_Run_URL__c, Last_Deployed_On__c,
                   (SELECT Id FROM Data_Templates__r)
            FROM CDO_Data_Set__c
            ORDER BY Name
            LIMIT 500
        ];
    }

    @AuraEnabled(cacheable=true)
    public static DataSetView getDataSet(Id dataSetId) {
        DataSetView view = new DataSetView();
        if (dataSetId == null) {
            return view;
        }
        List<CDO_Data_Set__c> rows = [
            SELECT Id, Name, Description__c, Status__c, Project__c, Project__r.Name,
                   Source_Environment__c, Source_Environment__r.Name, Source_Environment__r.Pipeline_Key__c,
                   Target_Environment__c, Target_Environment__r.Name, Target_Environment__r.Pipeline_Key__c,
                   Last_Run_URL__c, Last_Deployed_On__c
            FROM CDO_Data_Set__c
            WHERE Id = :dataSetId
        ];
        if (rows.isEmpty()) {
            return view;
        }
        view.dataSet = rows[0];
        view.templates = queryTemplates(dataSetId);
        view.relationships = queryRelationships(dataSetId);
        return view;
    }

    /** Environments a data set can move records between (everything except the hub itself). */
    @AuraEnabled(cacheable=true)
    public static List<CDO_Environment__c> getEnvironments() {
        return [
            SELECT Id, Name, Pipeline_Key__c, Type__c, Project__c
            FROM CDO_Environment__c
            WHERE Pipeline_Key__c != null AND (Type__c = null OR Type__c != 'Hub')
            ORDER BY Name
            LIMIT 200
        ];
    }

    /**
     * Creates or updates a template. The object, fields and external id are checked against this
     * org's schema when the object exists here; objects that exist only in the target orgs are
     * accepted as typed.
     */
    @AuraEnabled
    public static Id saveTemplate(CDO_Data_Template__c t) {
        if (t == null) {
            throw fail('Nothing to save.');
        }
        if (t.Id == null && t.Data_Set__c == null) {
            throw fail('Choose the data set this template belongs to.');
        }
        String objectName = t.Object_API_Name__c == null ? null : t.Object_API_Name__c.trim();
        if (String.isBlank(objectName)) {
            throw fail('Enter the object API name, for example Account.');
        }
        List<String> fieldList = splitFields(t.Fields__c);
        if (fieldList.isEmpty()) {
            throw fail('List at least one field to extract, for example Name, Industry.');
        }
        if (t.Record_Limit__c != null && t.Record_Limit__c <= 0) {
            throw fail('Record limit must be a positive number, or blank for no limit.');
        }
        String filter = t.Filter__c == null ? null : t.Filter__c.trim();
        if (filter != null && filter.toLowerCase().startsWith('where ')) {
            filter = filter.substring(6).trim();
        }
        validateAgainstSchema(objectName, fieldList, t.External_Id_Field__c);

        CDO_Data_Template__c rec = new CDO_Data_Template__c(Id = t.Id);
        if (t.Id == null) {
            rec.Data_Set__c = t.Data_Set__c;
        }
        rec.Name = String.isBlank(t.Name) ? objectName.abbreviate(80) : t.Name.trim().abbreviate(80);
        rec.Object_API_Name__c = objectName;
        rec.Fields__c = String.join(fieldList, ',');
        rec.Filter__c = String.isBlank(filter) ? null : filter;
        rec.External_Id_Field__c = String.isBlank(t.External_Id_Field__c) ? null : t.External_Id_Field__c.trim();
        rec.Order__c = t.Order__c;
        rec.Record_Limit__c = t.Record_Limit__c;
        try {
            upsert rec;
            return rec.Id;
        } catch (Exception e) {
            throw fail('Could not save the template: ' + messageOf(e));
        }
    }

    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        List<CDO_Data_Template__c> rows = templateId == null ? new List<CDO_Data_Template__c>() :
            [SELECT Id FROM CDO_Data_Template__c WHERE Id = :templateId];
        if (rows.isEmpty()) {
            return;
        }
        try {
            delete [SELECT Id FROM CDO_Data_Relationship__c WHERE Parent_Template__c = :templateId OR Child_Template__c = :templateId];
            delete rows;
        } catch (Exception e) {
            throw fail('Could not delete the template: ' + messageOf(e));
        }
    }

    /**
     * Dispatches sf-data-deploy.yml. sourceEnv/targetEnv are pipeline keys; blank means the data
     * set's own source/target environment.
     */
    @AuraEnabled
    public static String deployDataSet(Id dataSetId, String sourceEnv, String targetEnv) {
        DataSetView view = getDataSet(dataSetId);
        if (view.dataSet == null) {
            throw fail('That data set no longer exists or you do not have access to it.');
        }
        CDO_Data_Set__c ds = view.dataSet;
        String source = String.isNotBlank(sourceEnv) ? sourceEnv.trim() : ds.Source_Environment__r?.Pipeline_Key__c;
        String target = String.isNotBlank(targetEnv) ? targetEnv.trim() : ds.Target_Environment__r?.Pipeline_Key__c;
        if (String.isBlank(source) || String.isBlank(target)) {
            throw fail('Choose both a source and a target environment.');
        }
        if (source == target) {
            throw fail('The source and target environments must differ.');
        }
        if (ds.Status__c == 'Deploying') {
            throw fail(ds.Name + ' is already deploying' + (String.isBlank(ds.Last_Run_URL__c) ? '.' : ': ' + ds.Last_Run_URL__c));
        }
        if (view.templates.isEmpty()) {
            throw fail('Add at least one template to ' + ds.Name + ' before deploying it.');
        }
        String plan = EncodingUtil.base64Encode(Blob.valueOf(buildPlanJson(ds, view.templates, view.relationships)));
        IntegrationController.dispatchOrFail(GitHubService.WF_DATA_DEPLOY, new Map<String, String>{
            'data_set_id' => ds.Id,
            'source_env' => source,
            'target_env' => target,
            'plan' => plan
        });
        try {
            update new CDO_Data_Set__c(Id = ds.Id, Status__c = 'Deploying');
            CDO_Audit.log('Data', ('Data set ' + ds.Name + ' deploy ' + source + ' → ' + target + ' by ' + UserInfo.getName()).abbreviate(255),
                view.templates.size() + ' template(s)', new Map<String, Id>());
        } catch (Exception e) {
            throw fail('The data deploy was started, but the data set could not be updated: ' + messageOf(e));
        }
        return 'Deploying ' + ds.Name + ' from ' + source + ' to ' + target + '.';
    }

    /** The plan JSON from CONTRACTS.md section 5 (before base64). */
    @TestVisible
    private static String buildPlanJson(CDO_Data_Set__c ds, List<CDO_Data_Template__c> templates, List<CDO_Data_Relationship__c> relationships) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeStringField('dataSet', ds.Name);
        gen.writeFieldName('templates');
        gen.writeStartArray();
        Integer position = 0;
        for (CDO_Data_Template__c t : templates) {
            position++;
            gen.writeStartObject();
            gen.writeStringField('name', t.Name);
            gen.writeStringField('object', t.Object_API_Name__c);
            gen.writeFieldName('fields');
            gen.writeStartArray();
            for (String f : splitFields(t.Fields__c)) {
                gen.writeString(f);
            }
            gen.writeEndArray();
            if (String.isNotBlank(t.Filter__c)) {
                gen.writeStringField('filter', t.Filter__c);
            }
            if (String.isNotBlank(t.External_Id_Field__c)) {
                gen.writeStringField('externalId', t.External_Id_Field__c);
            }
            gen.writeNumberField('order', t.Order__c != null ? t.Order__c.intValue() : position);
            if (t.Record_Limit__c != null) {
                gen.writeNumberField('limit', t.Record_Limit__c.intValue());
            }
            gen.writeEndObject();
        }
        gen.writeEndArray();
        gen.writeFieldName('relationships');
        gen.writeStartArray();
        for (CDO_Data_Relationship__c r : relationships) {
            if (r.Parent_Template__r == null || r.Child_Template__r == null) {
                continue;
            }
            gen.writeStartObject();
            gen.writeStringField('parent', r.Parent_Template__r.Name);
            gen.writeStringField('child', r.Child_Template__r.Name);
            gen.writeStringField('field', r.Relationship_Field__c == null ? '' : r.Relationship_Field__c);
            gen.writeEndObject();
        }
        gen.writeEndArray();
        gen.writeEndObject();
        return gen.getAsString();
    }

    // ----------------------------------------------------------------------------------------

    private static List<CDO_Data_Template__c> queryTemplates(Id dataSetId) {
        return [
            SELECT Id, Name, Data_Set__c, Object_API_Name__c, Fields__c, Filter__c, External_Id_Field__c, Order__c, Record_Limit__c
            FROM CDO_Data_Template__c
            WHERE Data_Set__c = :dataSetId
            ORDER BY Order__c ASC NULLS LAST, Name
            LIMIT 500
        ];
    }

    private static List<CDO_Data_Relationship__c> queryRelationships(Id dataSetId) {
        return [
            SELECT Id, Name, Relationship_Field__c, Parent_Template__c, Parent_Template__r.Name,
                   Child_Template__c, Child_Template__r.Name
            FROM CDO_Data_Relationship__c
            WHERE Data_Set__c = :dataSetId
            ORDER BY Name
            LIMIT 500
        ];
    }

    private static List<String> splitFields(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) {
            return out;
        }
        Set<String> seen = new Set<String>();
        for (String part : raw.split('[,\\s]+')) {
            String f = part.trim();
            if (String.isNotBlank(f) && seen.add(f.toLowerCase())) {
                out.add(f);
            }
        }
        return out;
    }

    private static void validateAgainstSchema(String objectName, List<String> fieldList, String externalId) {
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectName);
        if (sType == null) {
            return; // may exist only in the source/target orgs
        }
        Map<String, Schema.SObjectField> fields = sType.getDescribe().fields.getMap();
        List<String> unknown = new List<String>();
        for (String f : fieldList) {
            if (!f.contains('.') && !fields.containsKey(f.toLowerCase())) {
                unknown.add(f);
            }
        }
        if (!unknown.isEmpty()) {
            throw fail(objectName + ' has no field named ' + String.join(unknown, ', ') + '.');
        }
        if (String.isNotBlank(externalId)) {
            Schema.SObjectField ext = fields.get(externalId.trim().toLowerCase());
            if (ext == null) {
                throw fail(objectName + ' has no field named ' + externalId.trim() + ' to use as the external id.');
            }
            Schema.DescribeFieldResult d = ext.getDescribe();
            if (!d.isExternalId() && !d.isIdLookup()) {
                throw fail(externalId.trim() + ' is not an external id or lookup field on ' + objectName + '.');
            }
        }
    }

    private static String messageOf(Exception e) {
        if (e instanceof DmlException) {
            return ((DmlException) e).getDmlMessage(0);
        }
        return e.getMessage();
    }

    private static AuraHandledException fail(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // ----------------------------------------------------------------------------------------

    public class DataSetView {
        @AuraEnabled public CDO_Data_Set__c dataSet;
        @AuraEnabled public List<CDO_Data_Template__c> templates = new List<CDO_Data_Template__c>();
        @AuraEnabled public List<CDO_Data_Relationship__c> relationships = new List<CDO_Data_Relationship__c>();
    }
}
