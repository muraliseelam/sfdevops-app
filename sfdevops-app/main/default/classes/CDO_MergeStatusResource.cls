/**
 * POST /services/apexrest/cdo/merge-status (docs/CONTRACTS.md section 2.2): the post-deploy merge
 * outcome of a promotion. Same error handling as the deploy callback: HTTP 400 or 500 with a JSON
 * CallbackResponse, and nothing half-applied is kept.
 */
@RestResource(urlMapping='/cdo/merge-status/*')
global with sharing class CDO_MergeStatusResource {

    global class MergeStatusRequest {
        public String promotionId;
        public String workItem;
        public String environment;
        public String targetBranch;
        public String mergeSha;
        public Boolean merged;
        public String reason;
        public String runUrl;
    }

    @HttpPost
    global static void handleMergeStatus() {
        RestRequest request = RestContext.request;
        String body = request == null || request.requestBody == null ? null : request.requestBody.toString();
        if (String.isBlank(body)) {
            CDO_CallbackResource.writeResponse(400, new CDO_CallbackResource.CallbackResponse(false, null, 'The merge-status body is empty.'));
            return;
        }
        MergeStatusRequest req;
        try {
            req = (MergeStatusRequest) JSON.deserialize(body, MergeStatusRequest.class);
        } catch (Exception e) {
            reject(400, 'Malformed merge-status JSON: ' + e.getMessage(), body);
            return;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            CDO_CallbackResource.writeResponse(200, new SystemContext().apply(req));
        } catch (CDO_CallbackService.CallbackException e) {
            Database.rollback(sp);
            reject(400, e.getMessage(), body);
        } catch (Exception e) {
            Database.rollback(sp);
            reject(500, 'The hub could not apply the merge status: ' + e.getTypeName() + ': ' + e.getMessage(), body);
        }
    }

    private static void reject(Integer statusCode, String message, String body) {
        try {
            new SystemContext().logRejection('Merge status rejected (HTTP ' + statusCode + '): ' + message, body);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Could not audit a rejected merge status: ' + e.getMessage());
        }
        CDO_CallbackResource.writeResponse(statusCode, new CDO_CallbackResource.CallbackResponse(false, null, message));
    }

    /**
     * without sharing, deliberately and narrowly: the caller is the pipeline's integration user, and
     * the promotion and work items it reports on belong to other users. CDO_MergeStatusService is
     * `inherited sharing`, so it runs in this context only when reached through this resource.
     */
    private without sharing class SystemContext {
        public CDO_CallbackResource.CallbackResponse apply(MergeStatusRequest req) {
            return CDO_MergeStatusService.apply(req);
        }

        public void logRejection(String summary, String body) {
            String previous = CDO_Audit.getSource();
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
            try {
                CDO_Audit.log('MergeStatusRejected', summary, body, null);
            } finally {
                CDO_Audit.setSource(previous);
            }
        }
    }
}
