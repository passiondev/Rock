<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ApplePayMobileDetail.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ApplePayMobileDetail" %>

<script>
    function visible() {

        document.getElementById('<%=pnlCSRDetails.ClientID %>').style.display = 'none';
        document.getElementById('<%=pnlCertificateUploadDetails.ClientID %>').style.display = 'block';
    }
</script>
<asp:UpdatePanel ID="upnlContent" runat="server">

    <ContentTemplate>

        <asp:Panel ID="pnlApplePayDetail" CssClass="panel panel-block" runat="server">
            <!-- Show the heading of Apple Pay Configuration screen -->
            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-archive"></i>
                    <asp:Literal ID="lTitle" Text="Apple Pay Certificate" runat="server" />
                </h1>
                <div class="panel-labels">
                    <Rock:HighlightLabel ID="hlStatus" runat="server" />
                </div>
            </div>
            <div class="panel-body">
                <div style="margin: 0 auto; width: 690px; max-width: 100%;">
                    <div class="mb-5">
                        <div class="text-center">
                            <asp:Image ID="imgMyWellLogo" CssClass="width-half margin-b-lg" runat="server" />
                        </div>
                        <asp:Panel ID="pnlDetails" runat="server">
                            <!-- Errors that happen during apple domain verification -->
                            <asp:Panel ID="pnErrorMessage" Visible="false" runat="server">
                                <div class="mt-4 alert alert-danger rounded-lg shadow-lg">
                                    <asp:Label ID="lErrorMessageTitle" runat="server"></asp:Label>
                                    <p class="pt-3">
                                        <asp:Label ID="lErrorBody" runat="server" />
                                    </p>
                                </div>
                            </asp:Panel>
                        </asp:Panel>
                        <asp:Panel ID="pnlCSRDetails" runat="server">
                            <p>
                                <asp:Literal runat="server" ID="lCsrStep1" Text="1. Start by selecting the Financial Gateway and downloading a CSR file." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lCsrStep2" Text="2. You'll use this Certificate Signing Request to get a secure certificate from Apple that will allow you to use Apple Pay for iOS." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lCsrStep3" Text="3. Once you've saved the CSR file, we'll walk you through the process of exchanging this file for a certificate on Apple's Developer site." />
                            </p>
                            <Rock:FinancialGatewayPicker ID="fgFinancialGateway" Visible="true" Required="true" runat="server" Label="Financial Gateway" Help="This is the financial gateway you will use to process transactions from Rock Mobile." />
                            <div class="text-center margin-t-xl">
                                <asp:LinkButton ID="btnDownloadCSR" runat="server" OnClick="btnDownloadCSR_Click" CssClass="btn btn-primary" Text="Download CSR" OnClientClick="if(Page_ClientValidate()) visible();" />
                            </div>
                        </asp:Panel>
                        <asp:Panel ID="pnlCertificateUploadDetails" runat="server" Style="display: none">
                            <p>
                                <asp:Label runat="server" ID="lUploadStepGeneral" Text="<strong>The generated CSR will download shortly. Once downloaded, follow the steps below to continue.</strong>" />
                            </p>
                            <br />
                            <p>
                                <asp:Label runat="server" ID="lUploadStep1" Text="1. Navigate to <a target='_blank' href='https://developer.apple.com/account/resources/identifiers/list/merchant'>this</a> page on your Apple's Developer account." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lUploadStep2" Text="2. Select the Merchant ID you'd like to add this certificate to." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lUploadStep3" Text="3. Under the 'Apple Pay Payment Processing Certificate' section click on 'Create Certificate'." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lUploadStep4" Text="4. When prompted to upload a 'Certificate Signing Request', choose the .certSigningRequest file you just downloaded." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lUploadStep5" Text="5. When prompted download the certificate and activate it if needed." />
                            </p>
                            <p>
                                <asp:Literal runat="server" ID="lUploadStep6" Text="6. Upload the certificate file below and click Submit." />
                            </p>
                            <br />
                            <p>
                                <asp:Literal runat="server" ID="lUploadStepNote" Text="<em><strong>Note: If a certificate was previously uploaded, the old certificate will be overwritten with the new certificate.</strong></em>" />
                            </p>

                            <Rock:FileUploader ID="fuUploader" runat="server" DisplayMode="DropZone" IsBinaryFile="true" Label="Upload Certificate" RequiredErrorMessage="A certificate file is required." FormGroupCssClass="fileupload-group-lg" UploadButtonText="Drop Certificate Here or Click to Select"></Rock:FileUploader>

                            <div class="text-center margin-t-xl">
                                <asp:LinkButton ID="btnUploadCertificate" runat="server" CssClass="btn btn-primary" Text="Upload" OnClick="btnUploadCertificate_Click" />
                            </div>
                        </asp:Panel>
                        <asp:Literal runat="server" ID="lUploadSuccess" Visible="false" Text="Certificate has been uploaded. You are ready to accept donations on iOS." /></p>

                    </div>

                    <div class="text-center margin-t-lg margin-b-lg">
                        <a href="https://www.mywell.org">https://www.mywell.org</a>
                    </div>
                </div>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>
