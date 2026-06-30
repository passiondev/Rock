<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ApplePayList.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ApplePayList" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <Rock:NotificationBox ID="nbWarningMessage" runat="server" NotificationBoxType="Danger" Visible="true" />
        <asp:Panel ID="pnlImportList" runat="server">
            <asp:HiddenField ID="hfAction" runat="server" />
            <div class="panel panel-block">
                <div class="panel-heading">
                    <h1 class="panel-title"><i class="fa fa-archive"></i>&nbsp;Apple Pay Domain List</h1>
                </div>
                <div class="panel-body">
                    <asp:Panel ID="pnlList" runat="server" Visible="true">
                        <asp:Panel ID="pnlValues" runat="server">
                            <Rock:ModalAlert ID="mdGridWarningValues" runat="server" />
                            <div class="grid grid-panel">
                                <Rock:Grid ID="gApplePayList" runat="server" AllowPaging="false" DisplayType="Full" OnRowSelected="gApplePayList_Edit" AllowSorting="False">
                                    <Columns>
                                        <Rock:RockBoundField DataField="DomainName" HeaderText="Domain Name" />
                                        <Rock:RockBoundField DataField="BenevityId" HeaderText="Benevity Id" />
                                        <Rock:RockBoundField DataField="MerchantId" HeaderText="Merchant Id" />
                                        <Rock:RockLiteralField ID="lFinancialGatewayName" HeaderText="Financial Gateway" />
                                        <Rock:RockLiteralField HeaderText="Status" ID="lVerificationtStatus" HeaderStyle-CssClass="grid-columnstatus" ItemStyle-CssClass="grid-columnstatus" FooterStyle-CssClass="grid-columnstatus" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" OnDataBound="lVerifiedStatus_DataBound" />
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
