import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getProjects from '@salesforce/apex/PipelineController.getProjects';
import getReleases from '@salesforce/apex/ReleaseController.getReleases';
import getSourceOrgs from '@salesforce/apex/WorkItemController.getSourceOrgs';
import createWorkItem from '@salesforce/apex/WorkItemController.createWorkItem';
import { recordPageRef, showError, showToast } from 'c/cdoUtils';

const TEST_LEVEL_OPTIONS = [
    { label: 'Default (resolved from the change)', value: '' },
    { label: 'No tests', value: 'NoTestRun' },
    { label: 'Specified tests', value: 'RunSpecifiedTests' },
    { label: 'Local tests', value: 'RunLocalTests' },
    { label: 'All tests in org', value: 'RunAllTestsInOrg' }
];

/**
 * Create a work item through WorkItemController.createWorkItem (and so CDO_WorkItemService),
 * then open it.
 */
export default class CdoNewWorkItem extends NavigationMixin(LightningElement) {
    subject = '';
    projectId;
    releaseId = '';
    sourceOrg = '';
    storyPoints;
    description = '';
    acceptanceCriteria = '';
    minimumCoverage;
    testLevel = '';
    specifiedTests = '';
    saving = false;

    projects = [];
    releases = [];
    sourceOrgs = [];
    testLevelOptions = TEST_LEVEL_OPTIONS;

    @wire(getProjects)
    wiredProjects({ data }) {
        if (data) {
            this.projects = data;
            if (!this.projectId && data.length) {
                this.projectId = data[0].Id;
            }
        }
    }

    @wire(getReleases, { projectId: '$projectId' })
    wiredReleases({ data }) {
        if (data) {
            this.releases = data.filter((r) => !r.locked);
        }
    }

    @wire(getSourceOrgs)
    wiredSourceOrgs({ data }) {
        if (data) {
            this.sourceOrgs = data;
        }
    }

    get projectOptions() {
        return this.projects.map((p) => ({ label: p.Name, value: p.Id }));
    }

    get showProjectPicker() {
        return this.projects.length > 1;
    }

    get noProjects() {
        return this.projects.length === 0;
    }

    get releaseOptions() {
        return [{ label: 'None', value: '' }, ...this.releases.map((r) => ({ label: r.name, value: r.id }))];
    }

    get sourceOrgOptions() {
        return [
            { label: 'Choose later', value: '' },
            ...this.sourceOrgs.map((o) => ({ label: o.Name, value: o.Pipeline_Key__c || o.Org_Alias__c || o.Name }))
        ];
    }

    get showSpecifiedTests() {
        return this.testLevel === 'RunSpecifiedTests';
    }

    get saveDisabled() {
        return this.saving;
    }

    handleChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail.value !== undefined ? event.detail.value : event.target.value;
        this[field] = value;
    }

    handleReset() {
        this.subject = '';
        this.releaseId = '';
        this.sourceOrg = '';
        this.storyPoints = undefined;
        this.description = '';
        this.acceptanceCriteria = '';
        this.minimumCoverage = undefined;
        this.testLevel = '';
        this.specifiedTests = '';
        this.template.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach((el) => {
            if (el.setCustomValidity) {
                el.setCustomValidity('');
            }
        });
    }

    async handleSave() {
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox')];
        const valid = inputs.reduce((ok, el) => el.reportValidity() && ok, true);
        if (!valid || !this.subject.trim()) {
            return;
        }
        const fields = {
            Subject__c: this.subject.trim(),
            Project__c: this.projectId || null,
            Release__c: this.releaseId || null,
            Source_Org_Alias__c: this.sourceOrg || null,
            Story_Points__c: this.storyPoints === '' ? null : this.storyPoints,
            Description__c: this.description || null,
            Acceptance_Criteria__c: this.acceptanceCriteria || null,
            Minimum_Coverage__c: this.minimumCoverage === '' ? null : this.minimumCoverage,
            Test_Level_Override__c: this.testLevel || null,
            Specified_Tests__c: this.showSpecifiedTests ? this.specifiedTests || null : null
        };
        Object.keys(fields).forEach((k) => {
            if (fields[k] === null || fields[k] === undefined) {
                delete fields[k];
            }
        });
        this.saving = true;
        try {
            const recordId = await createWorkItem({ fields });
            showToast(this, 'Work item created', `${this.subject.trim()} was created.`, 'success');
            this.handleReset();
            this[NavigationMixin.Navigate](recordPageRef(recordId, 'CDO_Work_Item__c'));
        } catch (e) {
            showError(this, 'Could not create the work item', e);
        } finally {
            this.saving = false;
        }
    }
}
