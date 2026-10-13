import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getPromotionPreview from '@salesforce/apex/PromotionController.getPromotionPreview';
import promoteWorkItem from '@salesforce/apex/PromotionController.promoteWorkItem';
import { refreshApex } from '@salesforce/apex';
import { errorMessage, recordUrl } from 'c/cdoUtils';

/**
 * Record action on a work item: Promote to the next stage and queue the deployment. It starts as soon as the stage is free.
 * Lightning record actions cannot take design attributes, so the Draft and the Deploy variants
 * are two bundles that differ only in the Apex method they call.
 */
export default class CdoPromoteDeployAction extends LightningElement {
    @api recordId;

    preview;
    loadError;
    working = false;
    previewResult;
    refreshed = false;

    @wire(getPromotionPreview, { workItemId: '$recordId' })
    wiredPreview(result) {
        this.previewResult = result;
        const { data, error } = result;
        if (data && !this.refreshed) {
            // The preview is cacheable; re-read once so a promotion made a moment ago is seen.
            this.refreshed = true;
            refreshApex(result);
        }
        if (data) {
            this.preview = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = errorMessage(error);
            this.preview = undefined;
        }
    }

    get isLoading() {
        return !this.preview && !this.loadError;
    }

    get blockedReason() {
        // Promote & Deploy is also held when coverage is below the work item's minimum.
        return this.loadError || (this.preview && (this.preview.blockedReason || this.preview.deployBlockedReason));
    }

    get fromLabel() {
        return this.preview && this.preview.currentStageName ? this.preview.currentStageName : 'the backlog';
    }

    get disabled() {
        return this.working || !this.preview || !this.preview.canDeploy;
    }

    async handlePromote() {
        this.working = true;
        try {
            const result = await promoteWorkItem({ workItemId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Promotion queued',
                    message: '{0}: ' + result.message,
                    messageData: [{ url: recordUrl(result.promotionId, 'CDO_Promotion__c'), label: result.promotionName }],
                    variant: 'success'
                })
            );
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.close();
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not promote', message: errorMessage(e), variant: 'error', mode: 'sticky' })
            );
        } finally {
            this.working = false;
        }
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
