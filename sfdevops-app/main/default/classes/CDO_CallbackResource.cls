/**
 * Inbound contract #2: POST /services/apexrest/cdo/deploy-callback (docs/CONTRACTS.md section 2.1).
 *
 * The pipeline posts one JSON object per event. Unknown attributes are ignored (JSON.deserialize, not
 * deserializeStrict), so the pipeline can add fields without breaking an older hub. A request the hub
 * cannot apply gets HTTP 400 (bad input) or 500 (hub error) with a JSON CallbackResponse, never an
 * unhandled exception, and nothing it half-applied is kept.
 */
@RestResource(urlMapping='/cdo/deploy-callback/*')
global with sharing class CDO_CallbackResource {

    global class CallbackRequest {
        public String deploymentId;          // hub Id, when the hub created the row
        public String promotionId;           // hub Id; blank = work-item-scoped event
        public String releaseId;             // hub Id, release events
        public String status;                // Running | Success | Failed | Cancelled
        public String message;
        public String runUrl;
        public String commitSha;
        public String workItem;              // work item key, e.g. WI-0032 (CDO_Work_Item__c.Name)
        public String environment;           // pipeline key, e.g. int, qa, prod
        public String eventType;             // Commit | Validation | Deploy | QuickDeploy | PullRequest |
                                             // Approval | Conflict | Merge | Release | Data | Rollback
        public String pullRequestUrl;
        public Integer pullRequestNumber;
        public Boolean pullRequestsApproved;
        public String reviewState;           // Pending | Approved | Changes_Requested
        public String approver;              // GitHub login
        public String approvalMethod;        // Review | Label | Manual | Environment
        public Decimal coveragePercent;      // literal percent: 87.5 means 87.5 %
        public Boolean testsPassed;
        public String failingMethods;        // newline-separated "Class.method: message"
        public String deployId;              // Salesforce deploy job id
        public Boolean checkOnly;
        public String testLevel;
        public Integer componentCount;
        public String promotionBranch;
        public String targetShaAtCut;
        public String conflictPaths;         // newline-separated paths
        public List<ComponentPayload> components;
        public List<FindingPayload> findings;
    }

    global class ComponentPayload {
        public String type;
        public String name;
        public String action;
        public String uniqueId;
        public String path;
        public String lastCommitDate;
        public String lastCommitSha;
    }

    global class FindingPayload {
        public String tool;
        public String rule;
        public String severity;
        public String file;
        public String message;
        public Integer line;
    }

    global class CallbackResponse {
        public Boolean success;
        public String deploymentId;
        public String message;

        public CallbackResponse() {
        }

        public CallbackResponse(Boolean success, String deploymentId, String message) {
            this.success = success;
            this.deploymentId = deploymentId;
            this.message = message;
        }
    }

    @HttpPost
    global static void handleCallback() {
        RestRequest request = RestContext.request;
        String body = request == null || request.requestBody == null ? null : request.requestBody.toString();
        if (String.isBlank(body)) {
            writeResponse(400, new CallbackResponse(false, null, 'The callback body is empty.'));
            return;
        }
        CallbackRequest req;
        try {
            req = (CallbackRequest) JSON.deserialize(body, CallbackRequest.class);
        } catch (Exception e) {
            reject(400, 'Malformed callback JSON: ' + e.getMessage(), body);
            return;
        }
        if (req == null) {
            reject(400, 'The callback body is empty.', body);
            return;
        }
        if (String.isBlank(req.promotionId) && String.isBlank(req.workItem) && String.isBlank(req.releaseId) &&
            String.isBlank(req.deploymentId) && String.isBlank(req.environment)) {
            reject(400, 'The callback names no promotion, work item, release, deployment or environment.', body);
            return;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            writeResponse(200, new SystemContext().route(req));
        } catch (CDO_CallbackService.CallbackException e) {
            Database.rollback(sp);
            reject(400, e.getMessage(), body);
        } catch (Exception e) {
            Database.rollback(sp);
            reject(500, 'The hub could not apply the callback: ' + e.getTypeName() + ': ' + e.getMessage(), body);
        }
    }

    /** Writes the JSON response. Shared by the hub's other REST resources. */
    public static void writeResponse(Integer statusCode, CallbackResponse response) {
        RestResponse res = RestContext.response;
        if (res == null) {
            res = new RestResponse();
            RestContext.response = res;
        }
        res.statusCode = statusCode;
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(JSON.serialize(response));
    }

    private static void reject(Integer statusCode, String message, String body) {
        try {
            new SystemContext().logRejection('CallbackRejected', 'Deploy callback rejected (HTTP ' + statusCode + '): ' + message, body);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Could not audit a rejected callback: ' + e.getMessage());
        }
        writeResponse(statusCode, new CallbackResponse(false, null, message));
    }

    /**
     * without sharing, deliberately and narrowly. The caller is the pipeline's integration user (JWT,
     * auth-hub.sh). The records a callback must update (promotions, work items, environments,
     * deployments) belong to developers and release managers, and the pipeline is the authority on
     * what ran. Who may call this endpoint at all is controlled by access to this Apex class.
     * CDO_CallbackService is `inherited sharing`, so it runs in this context only when reached here.
     */
    private without sharing class SystemContext {
        public CallbackResponse route(CallbackRequest req) {
            if (String.isBlank(req.promotionId)) {
                return CDO_CallbackService.applyWorkItemEvent(req);
            }
            return CDO_CallbackService.apply(req);
        }

        public void logRejection(String eventType, String summary, String body) {
            String previous = CDO_Audit.getSource();
            CDO_Audit.setSource(CDO_Audit.SOURCE_GITHUB);
            try {
                CDO_Audit.log(eventType, summary, body, null);
            } finally {
                CDO_Audit.setSource(previous);
            }
        }
    }
}
