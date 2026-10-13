/**
 * GitHub integration settings and health: CDO_Settings__c (org defaults), outbound webhooks, a
 * connection test, and a health summary (settings complete, last callback received, Named
 * Credential reachable).
 *
 * Also the one place controllers dispatch a workflow synchronously (dispatchOrFail), used only
 * when nothing has been written yet in the transaction; after DML a dispatch must go through a
 * Queueable instead.
 */
public with sharing class IntegrationController {

    private static final Pattern GITHUB_NAME = Pattern.compile('^[A-Za-z0-9_.-]{1,100}$');
    private static final Pattern API_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,79}$');

    @AuraEnabled(cacheable=true)
    public static CDO_Settings__c getSettings() {
        CDO_Settings__c s = CDO_Settings__c.getOrgDefaults();
        return s == null ? new CDO_Settings__c() : s;
    }

    /** Saves the org-default settings. Needs CDO_Configure_Pipeline. */
    @AuraEnabled
    public static CDO_Settings__c saveSettings(CDO_Settings__c s) {
        assertConfigure();
        if (s == null) {
            throw fail('Nothing to save.');
        }
        if (String.isNotBlank(s.GitHub_Owner__c) && !GITHUB_NAME.matcher(s.GitHub_Owner__c.trim()).matches()) {
            throw fail('GitHub owner may contain only letters, digits, "-", "_" and ".".');
        }
        if (String.isNotBlank(s.GitHub_Repo__c) && !GITHUB_NAME.matcher(s.GitHub_Repo__c.trim()).matches()) {
            throw fail('GitHub repo may contain only letters, digits, "-", "_" and ".". Enter the name only, not owner/repo.');
        }
        if (String.isNotBlank(s.Named_Credential__c) && !API_NAME.matcher(s.Named_Credential__c.trim()).matches()) {
            throw fail('Named Credential must be an API name, for example GitHub_API.');
        }
        if (s.Promotion_Timeout_Minutes__c != null && s.Promotion_Timeout_Minutes__c <= 0) {
            throw fail('Promotion timeout must be a positive number of minutes.');
        }
        CDO_Settings__c current = CDO_Settings__c.getOrgDefaults();
        CDO_Settings__c rec = new CDO_Settings__c(
            Id = current?.Id,
            SetupOwnerId = UserInfo.getOrganizationId(),
            GitHub_Owner__c = trimToNull(s.GitHub_Owner__c),
            GitHub_Repo__c = trimToNull(s.GitHub_Repo__c),
            Workflow_Ref__c = trimToNull(s.Workflow_Ref__c),
            Named_Credential__c = trimToNull(s.Named_Credential__c),
            Default_Project_Key__c = trimToNull(s.Default_Project_Key__c),
            Dispatch_Enabled__c = s.Dispatch_Enabled__c == true,
            Promotion_Timeout_Minutes__c = s.Promotion_Timeout_Minutes__c
        );
        try {
            upsert rec;
            CDO_Audit.log('Settings', ('SF DevOps Settings changed by ' + UserInfo.getName()).abbreviate(255),
                'Repository: ' + rec.GitHub_Owner__c + '/' + rec.GitHub_Repo__c + '\nRef: ' + rec.Workflow_Ref__c +
                    '\nNamed Credential: ' + rec.Named_Credential__c + '\nDispatch enabled: ' + rec.Dispatch_Enabled__c,
                new Map<String, Id>());
        } catch (Exception e) {
            throw fail('Could not save the settings: ' + messageOf(e));
        }
        return CDO_Settings__c.getOrgDefaults();
    }

    /** GET /repos/{owner}/{repo} through the Named Credential (GitHubService.send). */
    @AuraEnabled
    public static ConnectionResult testGitHubConnection() {
        ConnectionResult r = new ConnectionResult();
        List<String> missing = missingSettings(GitHubService.settings());
        if (!missing.isEmpty()) {
            r.message = 'Fill in SF DevOps Settings first: ' + String.join(missing, ', ') + '.';
            return r;
        }
        HttpResponse res = GitHubService.send('GET', '', null);
        Integer code = res == null ? 0 : res.getStatusCode();
        r.statusCode = code;
        r.repoUrl = GitHubService.repoUrl();
        r.ok = code == 200;
        if (r.ok) {
            r.message = 'Connected to ' + r.repoUrl + '.';
        } else if (code == 401 || code == 403) {
            r.message = 'GitHub refused the token (HTTP ' + code + '). Re-run bootstrap-secrets.sh to store a token with access to the repository.';
        } else if (code == 404) {
            r.message = 'GitHub returned 404 for ' + r.repoUrl + '. Check GitHub Owner and GitHub Repo in SF DevOps Settings, and that the token can see the repository.';
        } else if (code == 0) {
            r.message = responseMessage(res) + ' Check that the ' + GitHubService.namedCredential() +
                ' Named Credential exists and that your permission set grants its external credential principal.';
        } else {
            r.message = 'GitHub answered HTTP ' + code + ': ' + responseMessage(res);
        }
        return r;
    }

    @AuraEnabled(cacheable=true)
    public static List<CDO_Webhook__c> getWebhooks() {
        return [
            SELECT Id, Name, Named_Credential__c, Path__c, Events__c, Format__c, Active__c, Last_Status__c, Last_Sent_On__c
            FROM CDO_Webhook__c
            ORDER BY Name
            LIMIT 200
        ];
    }

    /** Creates or updates a webhook. Needs CDO_Configure_Pipeline. */
    @AuraEnabled
    public static Id saveWebhook(CDO_Webhook__c w) {
        assertConfigure();
        if (w == null) {
            throw fail('Nothing to save.');
        }
        if (String.isBlank(w.Name)) {
            throw fail('Enter a name for the webhook.');
        }
        if (String.isBlank(w.Named_Credential__c) || !API_NAME.matcher(w.Named_Credential__c.trim()).matches()) {
            throw fail('Enter the API name of the Named Credential the webhook posts through.');
        }
        String path = trimToNull(w.Path__c);
        if (path != null && !path.startsWith('/')) {
            path = '/' + path;
        }
        CDO_Webhook__c rec = new CDO_Webhook__c(
            Id = w.Id,
            Name = w.Name.trim().abbreviate(80),
            Named_Credential__c = w.Named_Credential__c.trim(),
            Path__c = path,
            Events__c = w.Events__c,
            Format__c = String.isBlank(w.Format__c) ? 'Generic_JSON' : w.Format__c,
            Active__c = w.Active__c == true
        );
        try {
            upsert rec;
            CDO_Audit.log('Settings', ('Webhook ' + rec.Name + ' saved by ' + UserInfo.getName()).abbreviate(255),
                'Named Credential: ' + rec.Named_Credential__c + '\nPath: ' + rec.Path__c + '\nEvents: ' + rec.Events__c,
                new Map<String, Id>());
            return rec.Id;
        } catch (Exception e) {
            throw fail('Could not save the webhook: ' + messageOf(e));
        }
    }

    /** Settings complete? Last callback received? Named Credential reachable? */
    @AuraEnabled
    public static Health getHealth() {
        Health h = new Health();
        CDO_Settings__c s = GitHubService.settings();
        h.missingSettings = missingSettings(s);
        h.settingsComplete = h.missingSettings.isEmpty();
        h.dispatchEnabled = s != null && s.Dispatch_Enabled__c == true;
        h.namedCredential = GitHubService.namedCredential();
        h.workflowRef = GitHubService.defaultRef();

        List<CDO_Audit_Event__c> last = [
            SELECT Id, Name, Event_Type__c, Summary__c, Occurred_On__c, CreatedDate, Run_URL__c
            FROM CDO_Audit_Event__c
            WHERE Source__c = 'GitHub'
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        if (!last.isEmpty()) {
            h.lastCallbackOn = last[0].Occurred_On__c != null ? last[0].Occurred_On__c : last[0].CreatedDate;
            h.lastCallbackSummary = last[0].Summary__c;
            h.lastCallbackEventId = last[0].Id;
            h.lastCallbackRunUrl = last[0].Run_URL__c;
        }

        if (!h.settingsComplete) {
            h.namedCredentialReachable = false;
            h.namedCredentialMessage = 'Not tested: settings are incomplete.';
        } else {
            ConnectionResult c = testGitHubConnection();
            h.namedCredentialReachable = c.ok;
            h.namedCredentialMessage = c.message;
            h.repoUrl = c.repoUrl;
        }
        h.healthy = h.settingsComplete && h.namedCredentialReachable && h.dispatchEnabled;
        return h;
    }

    // ----------------------------------------------------------------------------------------
    // Shared dispatch helper
    // ----------------------------------------------------------------------------------------

    /**
     * Dispatches a workflow now and throws an actionable AuraHandledException when GitHub does not
     * answer 204. Call it only before any DML in the transaction.
     */
    public static GitHubService.DispatchResult dispatchOrFail(String workflowFile, Map<String, String> inputs) {
        GitHubService.DispatchResult r;
        try {
            r = GitHubService.dispatchWorkflow(workflowFile, GitHubService.defaultRef(), inputs);
        } catch (Exception e) {
            throw fail('Could not start ' + workflowFile + ': ' + e.getMessage());
        }
        if (r == null || r.ok != true) {
            String reason = r == null || String.isBlank(r.message) ? 'GitHub did not start ' + workflowFile + '.' : r.message;
            throw fail(reason + ' ' + hintFor(r));
        }
        return r;
    }

    private static String hintFor(GitHubService.DispatchResult r) {
        if (r == null || r.statusCode == null || r.statusCode == 0) {
            return r != null && r.message != null && r.message.startsWith('Could not reach')
                ? 'Check the GitHub_API Named Credential and that your permission set grants its external credential principal.'
                : '';
        }
        if (r.statusCode == 401 || r.statusCode == 403) {
            return 'The GitHub token is missing or lacks the Actions and Workflows permissions. Re-run bootstrap-secrets.sh.';
        }
        if (r.statusCode == 404) {
            return 'The workflow file or the repository was not found. Check the owner, repo and ref in SF DevOps Settings.';
        }
        if (r.statusCode == 422) {
            return 'GitHub rejected the inputs or the ref. Check that the workflow exists on the configured ref.';
        }
        return 'Try again, and check the GitHub status page if it keeps failing.';
    }

    // ----------------------------------------------------------------------------------------

    private static List<String> missingSettings(CDO_Settings__c s) {
        List<String> missing = new List<String>();
        if (s == null || String.isBlank(s.GitHub_Owner__c)) {
            missing.add('GitHub Owner');
        }
        if (s == null || String.isBlank(s.GitHub_Repo__c)) {
            missing.add('GitHub Repo');
        }
        return missing;
    }

    private static String responseMessage(HttpResponse res) {
        if (res == null) {
            return 'No response.';
        }
        String body = res.getBody();
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof Map<String, Object> && ((Map<String, Object>) parsed).get('message') != null) {
                return String.valueOf(((Map<String, Object>) parsed).get('message'));
            }
        } catch (Exception e) {
            // not JSON; fall through to the raw body
        }
        return String.isBlank(body) ? res.getStatus() : body.abbreviate(300);
    }

    private static void assertConfigure() {
        if (!GovernanceController.hasPermission(GovernanceController.PERM_CONFIGURE_PIPELINE)) {
            throw fail('Changing pipeline settings needs the ' + GovernanceController.PERM_CONFIGURE_PIPELINE +
                ' permission (CDO_Pipeline_Admin_Access).');
        }
    }

    private static String trimToNull(String s) {
        return String.isBlank(s) ? null : s.trim();
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

    public class ConnectionResult {
        @AuraEnabled public Boolean ok = false;
        @AuraEnabled public Integer statusCode;
        @AuraEnabled public String message;
        @AuraEnabled public String repoUrl;
    }

    public class Health {
        @AuraEnabled public Boolean healthy = false;
        @AuraEnabled public Boolean settingsComplete = false;
        @AuraEnabled public List<String> missingSettings = new List<String>();
        @AuraEnabled public Boolean dispatchEnabled = false;
        @AuraEnabled public String namedCredential;
        @AuraEnabled public String workflowRef;
        @AuraEnabled public Boolean namedCredentialReachable = false;
        @AuraEnabled public String namedCredentialMessage;
        @AuraEnabled public String repoUrl;
        @AuraEnabled public Datetime lastCallbackOn;
        @AuraEnabled public String lastCallbackSummary;
        @AuraEnabled public Id lastCallbackEventId;
        @AuraEnabled public String lastCallbackRunUrl;
    }
}
