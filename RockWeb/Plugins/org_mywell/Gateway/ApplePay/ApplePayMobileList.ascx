<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ApplePayMobileList.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ApplePayMobileList" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <Rock:NotificationBox ID="nbWarningMessage" runat="server" NotificationBoxType="Danger" Visible="true" />
        <asp:Panel ID="pnlImportList" runat="server">
            <asp:HiddenField ID="hfAction" runat="server" />
            <div class="panel panel-block">
                <div class="panel-heading">
                    <h1 class="panel-title"><i class="fa fa-archive"></i>&nbsp;iOS Configuration List</h1>
                </div>
                <div class="panel-body">
                    <asp:Panel ID="pnlList" runat="server" Visible="true">
                        <asp:Panel ID="pnlValues" runat="server">
                            <Rock:ModalAlert ID="mdGridWarningValues" runat="server" />
                            <div class="grid grid-panel">
                                <Rock:Grid ID="gApplePayList" runat="server" AllowPaging="false" DisplayType="Full" AllowSorting="False">
                                    <Columns>
                                        <Rock:RockBoundField DataField="MerchantId" HeaderText="Merchant Id" />
                                        <Rock:RockBoundField DataField="CertificateId" HeaderText="Certificate Id" />
                                        <Rock:DateTimeField DataField="ValidFrom" HeaderText="Created"/>
                                        <Rock:DateTimeField DataField="ValidTo" HeaderText="Expires"/>
                                        <Rock:RockLiteralField ID="lFinancialGatewayName" HeaderText="Financial Gateway" />
                                    </Columns>
                                </Rock:Grid>
                            </div>
                        </asp:Panel>
                    </asp:Panel>
                </div>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>
