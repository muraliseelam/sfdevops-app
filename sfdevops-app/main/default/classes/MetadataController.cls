/**
 * The metadata a work item carries: its components, their dependency edges, and the overlap
 * pre-check (other in-flight work items that touch the same Unique_ID__c), which is what the
 * conflict checker joins on before a promotion merge would hit the clash.
 */
public with sharing class MetadataController {

    @AuraEnabled(cacheable=true)
    public static List<CDO_Component__c> getComponents(Id workItemId) {
        if (workItemId == null) {
            return new List<CDO_Component__c>();
        }
        return [
            SELECT Id, Name, Metadata_Type__c, Member_Name__c, Unique_ID__c, Work_Item_Key__c, Action__c, Path__c,
                   Last_Commit_Date__c, Last_Commit_SHA__c, Has_Conflict__c, Work_Item__c
            FROM CDO_Component__c
            WHERE Work_Item__c = :workItemId
            ORDER BY Metadata_Type__c, Member_Name__c, Id
            LIMIT 5000
        ];
    }

    /**
     * Stops tracking a component on its work item. The file stays on the feature branch until it
     * is removed there, so the message says so.
     */
    @AuraEnabled
    public static String removeComponent(Id componentId) {
        List<CDO_Component__c> rows = componentId == null ? new List<CDO_Component__c>() : [
            SELECT Id, Unique_ID__c, Work_Item__c, Work_Item__r.Name, Work_Item__r.Status__c
            FROM CDO_Component__c
            WHERE Id = :componentId
        ];
        if (rows.isEmpty()) {
            throw fail('That component no longer exists or you do not have access to it.');
        }
        CDO_Component__c c = rows[0];
        if (c.Work_Item__r.Status__c == 'Promoting') {
            throw fail(c.Work_Item__r.Name + ' is being promoted. Remove components after the promotion finishes.');
        }
        try {
            delete c;
            CDO_Audit.log(
                'Component',
                (c.Unique_ID__c + ' removed from ' + c.Work_Item__r.Name + ' by ' + UserInfo.getName()).abbreviate(255),
                'The component is no longer tracked on the work item. It stays on the feature branch until it is removed there.',
                new Map<String, Id>{ 'workItem' => c.Work_Item__c }
            );
            return c.Unique_ID__c + ' removed from ' + c.Work_Item__r.Name +
                '. It stays on the feature branch until you remove it there.';
        } catch (Exception e) {
            throw fail('Could not remove the component: ' + messageOf(e));
        }
    }

    /** What the component depends on, and what depends on it. */
    @AuraEnabled(cacheable=true)
    public static DependencyView getDependencies(Id componentId) {
        DependencyView view = new DependencyView();
        if (componentId == null) {
            return view;
        }
        List<CDO_Component__c> rows = [SELECT Id, Unique_ID__c FROM CDO_Component__c WHERE Id = :componentId];
        if (rows.isEmpty()) {
            return view;
        }
        String uniqueId = rows[0].Unique_ID__c;
        view.componentId = componentId;
        view.uniqueId = uniqueId;
        for (CDO_Component_Dependency__c d : [
            SELECT Id, Name, Dependency_Type__c, Depends_On__c, Depends_On__r.Unique_ID__c, Depends_On__r.Work_Item__r.Name,
                   Depends_On_Unique_ID__c
            FROM CDO_Component_Dependency__c
            WHERE Component__c = :componentId
            ORDER BY Depends_On_Unique_ID__c
            LIMIT 1000
        ]) {
            DependencyEdge e = new DependencyEdge();
            e.id = d.Id;
            e.dependencyType = d.Dependency_Type__c;
            e.uniqueId = d.Depends_On__c != null ? d.Depends_On__r.Unique_ID__c : d.Depends_On_Unique_ID__c;
            e.componentId = d.Depends_On__c;
            e.workItemName = d.Depends_On__r?.Work_Item__r?.Name;
            view.dependsOn.add(e);
        }
        String soql =
            'SELECT Id, Dependency_Type__c, Component__c, Component__r.Unique_ID__c, Component__r.Work_Item__r.Name ' +
            'FROM CDO_Component_Dependency__c WHERE Depends_On__c = :componentId' +
            (String.isBlank(uniqueId) ? '' : ' OR Depends_On_Unique_ID__c = :uniqueId') +
            ' ORDER BY Component__r.Unique_ID__c LIMIT 1000';
        Map<String, Object> binds = new Map<String, Object>{ 'componentId' => componentId, 'uniqueId' => uniqueId };
        for (CDO_Component_Dependency__c d : (List<CDO_Component_Dependency__c>) Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE)) {
            if (d.Component__c == componentId) {
                continue;
            }
            DependencyEdge e = new DependencyEdge();
            e.id = d.Id;
            e.dependencyType = d.Dependency_Type__c;
            e.uniqueId = d.Component__r?.Unique_ID__c;
            e.componentId = d.Component__c;
            e.workItemName = d.Component__r?.Work_Item__r?.Name;
            view.dependents.add(e);
        }
        return view;
    }

    /**
     * Other open work items that carry the same components (joined on Unique_ID__c). This is the
     * conflict pre-check: an overlap is not a conflict yet, but it is where one will happen.
     */
    @AuraEnabled(cacheable=true)
    public static List<Overlap> getOverlaps(Id workItemId) {
        List<Overlap> overlaps = new List<Overlap>();
        if (workItemId == null) {
            return overlaps;
        }
        Map<String, CDO_Component__c> mine = new Map<String, CDO_Component__c>();
        for (CDO_Component__c c : [
            SELECT Unique_ID__c, Metadata_Type__c, Member_Name__c
            FROM CDO_Component__c
            WHERE Work_Item__c = :workItemId AND Unique_ID__c != null
        ]) {
            mine.put(c.Unique_ID__c, c);
        }
        if (mine.isEmpty()) {
            return overlaps;
        }
        Set<String> uniqueIds = mine.keySet();
        Map<String, Overlap> byUniqueId = new Map<String, Overlap>();
        for (CDO_Component__c other : [
            SELECT Id, Unique_ID__c, Action__c, Has_Conflict__c, Last_Commit_Date__c,
                   Work_Item__c, Work_Item__r.Name, Work_Item__r.Subject__c, Work_Item__r.Status__c,
                   Work_Item__r.Current_Stage__r.Name, Work_Item__r.Developer__r.Name
            FROM CDO_Component__c
            WHERE Unique_ID__c IN :uniqueIds AND Work_Item__c != :workItemId
                  AND Work_Item__r.Status__c NOT IN :PipelineController.CLOSED_WORK_ITEM
            ORDER BY Unique_ID__c, Work_Item__r.Name
            LIMIT 2000
        ]) {
            Overlap o = byUniqueId.get(other.Unique_ID__c);
            if (o == null) {
                CDO_Component__c own = mine.get(other.Unique_ID__c);
                o = new Overlap();
                o.uniqueId = other.Unique_ID__c;
                o.metadataType = own.Metadata_Type__c;
                o.memberName = own.Member_Name__c;
                byUniqueId.put(other.Unique_ID__c, o);
                overlaps.add(o);
            }
            OverlapWorkItem w = new OverlapWorkItem();
            w.componentId = other.Id;
            w.workItemId = other.Work_Item__c;
            w.workItemName = other.Work_Item__r.Name;
            w.subject = other.Work_Item__r.Subject__c;
            w.status = other.Work_Item__r.Status__c;
            w.stageName = other.Work_Item__r.Current_Stage__r?.Name;
            w.developerName = other.Work_Item__r.Developer__r?.Name;
            w.action = other.Action__c;
            w.hasConflict = other.Has_Conflict__c;
            w.lastCommitDate = other.Last_Commit_Date__c;
            o.workItems.add(w);
            o.hasConflict = o.hasConflict || other.Has_Conflict__c;
        }
        return overlaps;
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

    public class DependencyView {
        @AuraEnabled public Id componentId;
        @AuraEnabled public String uniqueId;
        @AuraEnabled public List<DependencyEdge> dependsOn = new List<DependencyEdge>();
        @AuraEnabled public List<DependencyEdge> dependents = new List<DependencyEdge>();
    }

    public class DependencyEdge {
        @AuraEnabled public Id id;
        @AuraEnabled public String dependencyType;
        @AuraEnabled public String uniqueId;
        @AuraEnabled public Id componentId;
        @AuraEnabled public String workItemName;
    }

    public class Overlap {
        @AuraEnabled public String uniqueId;
        @AuraEnabled public String metadataType;
        @AuraEnabled public String memberName;
        @AuraEnabled public Boolean hasConflict = false;
        @AuraEnabled public List<OverlapWorkItem> workItems = new List<OverlapWorkItem>();
    }

    public class OverlapWorkItem {
        @AuraEnabled public Id componentId;
        @AuraEnabled public Id workItemId;
        @AuraEnabled public String workItemName;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String stageName;
        @AuraEnabled public String developerName;
        @AuraEnabled public String action;
        @AuraEnabled public Boolean hasConflict;
        @AuraEnabled public Datetime lastCommitDate;
    }
}
