<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ApplePayDetail.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ApplePayDetail" %>
<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <asp:HiddenField ID="hfApplePayDomaintId" runat="server" />

        <asp:Panel ID="pnlApplePayDetail" CssClass="panel panel-block" runat="server">
            <!-- Show the heading of Apple Pay Configuration screen -->
            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-archive"></i>
                    <asp:Literal ID="lTitle" Text="Apple Pay Domain Configuration" runat="server" />
                </h1>
                <div class="panel-labels">
                    <Rock:HighlightLabel ID="hlStatus" runat="server" />
                </div>
            </div>
            <Rock:PanelDrawer ID="pdAuditDetails" runat="server"></Rock:PanelDrawer>
            <div class="panel-body">
                <div style="margin: 0 auto; width: 690px; max-width: 100%;">
                    <div class="text-center mb-5">
                        <asp:Image ID="imgMyWellLogo" CssClass="width-half margin-b-lg" runat="server" />
                        <asp:Literal runat="server" ID="lDescription" />
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
                        <!-- Appe Pay Configuration Detail Page -->
                        <asp:Panel ID="pnlApplePayId" runat="server">
                            <div class="alert alert-info text-center margin-v-lg">
                                <b>Domain Name</b>
                                <p class="mb-3">
                                    <asp:Literal runat="server" ID="lDomainName" />
                                </p>
                                <b>Apple Pay Merchant Id</b>
                                <p class="mb-3">
                                    <asp:Literal runat="server" ID="lMyWellApplePayId" />
                                </p>
                                <b>Benevity Id</b>
                                <p>
                                    <asp:Literal runat="server" ID="lBenevityId" />
                                </p>
                            </div>
                        </asp:Panel>
                    </asp:Panel>
                    <!-- Apple Domain Verification Input Verification Page -->
                    <asp:Panel ID="pnlVerifyMode" runat="server">
                        <asp:Panel ID="pnVerifyFields" runat="server">
                            <Rock:RockTextBox ID="tbDomainName" runat="server" Label="Domain Name" Required="true" Help="The external site domain to verified with Apple. This domain is where you will accept apple pay transactions." />
                            <Rock:RockTextBox ID="tbBenevityId" runat="server" Label="Benevity ID" Required="true" Help="The benevity id associated to the organization for the gateway selecting below." />
                            <Rock:FinancialGatewayPicker ID="fgFinancialGateway" Required="true" runat="server" Label="Financial Gateway" Help="This is the financial gateway you are verifying the domain for apple pay." />
                            <div class="text-center margin-t-xl">
                                <asp:LinkButton ID="btnVerifyDomain" runat="server" CssClass="btn btn-primary" Text="Verify Domain" OnClick="btnVerifyDomain_Click" />
                            </div>
                        </asp:Panel>
                    </asp:Panel>
                    <asp:Panel ID="pnlCheckStatus" runat="server">
                        <div class="text-center margin-t-xl">
                            <asp:LinkButton ID="btnCheckStatus" runat="server" CssClass="btn btn-primary" Text="Check Status" OnClick="btnCheckStatus_Click" />
                        </div>
                    </asp:Panel>
                    <div class="text-center margin-t-lg margin-b-lg">
                        <a href="https://www.mywell.org">https://www.mywell.org</a>
                    </div>
                </div>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>
