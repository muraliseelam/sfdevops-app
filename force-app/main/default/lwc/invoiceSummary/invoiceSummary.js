import { LightningElement, api, wire } from 'lwc';
import getSummary from '@salesforce/apex/InvoiceController.getSummary';

export default class InvoiceSummary extends LightningElement {
    @api recordId;
    summary;
    error;

    @wire(getSummary, { accountId: '$recordId' })
    wired({ data, error }) {
        this.summary = data;
        this.error = error;
    }

    get hasData() {
        return !!this.summary;
    }

    get outstanding() {
        return this.summary ? this.summary.outstanding : 0;
    }

    get count() {
        return this.summary ? this.summary.count : 0;
    }
}
