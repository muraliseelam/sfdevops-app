/**
 * POST /services/apexrest/cdo/source-members (docs/CONTRACTS.md section 2.3): the changed source
 * members sf-list-changes.yml found in a developer org. They are stored newest-first on the work
 * item (Source_Changes_JSON__c, Source_Changes_Status__c = Received, Source_Changes_Received_On__c)
 * for the commit UI.
 */
@RestResource(urlMapping='/cdo/source-members/*')
global with sharing class CDO_SourceMemberResource {

    public static final Integer MAX_JSON_LENGTH = 131072;

    global class SourceMembersRequest {
        public String workItem;
        public String workItemId;
        public String requestId;
        public String sourceOrg;
        public String status;
        public String message;
        public List<SourceMember> members;
    }

    global class SourceMember {
        public String type;
        public String name;
        public String lastModifiedDate;
        public String lastModifiedBy;
        public String state;
    }

    @HttpPost
    global static void handleSourceMembers() {
        RestRequest request = RestContext.request;
        String body = request == null || request.requestBody == null ? null : request.requestBody.toString();
        if (String.isBlank(body)) {
            CDO_CallbackResource.writeResponse(400, new CDO_CallbackResource.CallbackResponse(false, null, 'The source-members body is empty.'));
            return;
        }
        SourceMembersRequest req;
        try {
            req = (SourceMembersRequest) JSON.deserialize(body, SourceMembersRequest.class);
        } catch (Exception e) {
            reject(400, 'Malformed source-members JSON: ' + e.getMessage(), body);
            return;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            CDO_CallbackResource.writeResponse(200, new SystemContext().store(req));
        } catch (CDO_CallbackService.CallbackException e) {
            Database.rollback(sp);
            reject(400, e.getMessage(), body);
        } catch (Exception e) {
            Database.rollback(sp);
            reject(500, 'The hub could not store the source members: ' + e.getTypeName() + ': ' + e.getMessage(), body);
        }
    }

    /** Newest lastModifiedDate first; members without a readable date go last; ties by type, then name. */
    public static List<SourceMember> newestFirst(List<SourceMember> members) {
        List<MemberSort> wrapped = new List<MemberSort>();
        if (members != null) {
            for (SourceMember m : members) {
                if (m != null) {
                    wrapped.add(new MemberSort(m));
                }
            }
        }
        wrapped.sort();
        List<SourceMember> out = new List<SourceMember>();
        for (MemberSort w : wrapped) {
            out.add(w.member);
        }
        return out;
    }

    private static void reject(Integer statusCode, String message, String body) {
        try {
            new SystemContext().logRejection('Source members rejected (HTTP ' + statusCode + '): ' + message, body);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Could not audit rejected source members: ' + e.getMessage());
        }
        CDO_CallbackResource.writeResponse(statusCode, new CDO_CallbackResource.CallbackResponse(false, null, message));
    }

    private class MemberSort implements Comparable {
        public SourceMember member;
        public Datetime modified;

        public MemberSort(SourceMember member) {
            this.member = member;
            this.modified = CDO_CallbackService.parseDatetime(member.lastModifiedDate);
        }

        public Integer compareTo(Object other) {
            MemberSort that = (MemberSort) other;
            if (modified != null && that.modified == null) {
                return -1;
            }
            if (modified == null && that.modified != null) {
                return 1;
            }
            if (modified != null && modified != that.modified) {
                return modified > that.modified ? -1 : 1;
            }
            String a = (member.type == null ? '' : member.type) + ':' + (member.name == null ? '' : member.name);
            String b = (that.member.type == null ? '' : that.member.type) + ':' + (that.member.name == null ? '' : that.member.name);
            return a.compareTo(b);
        }
    }

    /**
     * without sharing, deliberately and narrowly: the caller is the pipeline's integration user, and
     * the work item belongs to a developer. Only the three Source_Changes_* fields are written.
     */
    private without sharing class SystemContext {

        public CDO_CallbackResource.CallbackResponse store(SourceMembersRequest req) {
            if (req == null) {
                throw new CDO_CallbackService.CallbackException('The source-members body is empty.');
            }
            CDO_Work_Item__c wi = findWorkItem(req);
            String status = String.isBlank(req.status) ? '' : req.status.trim().toLowerCase();
            Boolean failed = status == 'failed' || status == 'failure' || status == 'error';
            CDO_Work_Item__c upd = new CDO_Work_Item__c(Id = wi.Id, Source_Changes_Received_On__c = System.now());
            String summary;
            Integer dropped = 0;
            if (failed) {
                upd.Source_Changes_Status__c = 'Failed';
                summary = 'Listing source changes for ' + wi.Name + ' failed' +
                    (String.isBlank(req.message) ? '.' : ': ' + req.message.trim());
            } else {
                List<SourceMember> sorted = newestFirst(req.members);
                Integer total = sorted.size();
                String payload = JSON.serialize(sorted, true);
                // Keep the newest members when the list does not fit the field.
                while (payload.length() > MAX_JSON_LENGTH && !sorted.isEmpty()) {
                    Integer cut = Math.max(1, sorted.size() / 10);
                    for (Integer i = 0; i < cut; i++) {
                        sorted.remove(sorted.size() - 1);
                    }
                    payload = JSON.serialize(sorted, true);
                }
                dropped = total - sorted.size();
                upd.Source_Changes_JSON__c = payload;
                upd.Source_Changes_Status__c = 'Received';
                summary = sorted.size() + ' changed source member' + (sorted.size() == 1 ? '' : 's') + ' received for ' +
                    wi.Name + (String.isBlank(req.sourceOrg) ? '' : ' from ' + req.sourceOrg.trim()) +
                    (dropped == 0 ? '.' : ' (' + dropped + ' oldest dropped to fit).');
            }
            update upd;

            String previous = CDO_Audit.getSource();
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
            try {
                CDO_Audit.log(
                    failed ? 'SourceMembers.Failed' : 'SourceMembers.Received',
                    summary,
                    'request_id: ' + req.requestId + '\nsource_org: ' + req.sourceOrg +
                    (String.isBlank(req.message) ? '' : '\nmessage: ' + req.message),
                    new Map<String, Id>{ 'workItem' => wi.Id }
                );
            } finally {
                CDO_Audit.setSource(previous);
            }
            return new CDO_CallbackResource.CallbackResponse(true, null, summary);
        }

        public void logRejection(String summary, String body) {
            String previous = CDO_Audit.getSource();
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
            try {
                CDO_Audit.log('SourceMembersRejected', summary, body, null);
            } finally {
                CDO_Audit.setSource(previous);
            }
        }

        private CDO_Work_Item__c findWorkItem(SourceMembersRequest req) {
            Id wiId = CDO_CallbackService.toId(req.workItemId, CDO_Work_Item__c.SObjectType, 'workItemId');
            List<CDO_Work_Item__c> rows;
            if (wiId != null) {
                rows = [SELECT Id, Name FROM CDO_Work_Item__c WHERE Id = :wiId];
            } else if (String.isNotBlank(req.workItem)) {
                String name = req.workItem.trim();
                rows = [SELECT Id, Name FROM CDO_Work_Item__c WHERE Name = :name LIMIT 1];
            } else {
                throw new CDO_CallbackService.CallbackException('workItem or workItemId is required.');
            }
            if (rows.isEmpty()) {
                throw new CDO_CallbackService.CallbackException(
                    'Unknown work item ' + (wiId != null ? String.valueOf(wiId) : req.workItem) + '.'
                );
            }
            return rows[0];
        }
    }
}
