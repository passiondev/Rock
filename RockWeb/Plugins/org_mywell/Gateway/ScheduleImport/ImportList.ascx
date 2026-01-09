<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ImportList.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ImportList" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <Rock:NotificationBox ID="nbWarningMessage" runat="server" NotificationBoxType="Danger" Visible="true" />
        <asp:Panel ID="pnlImportList" runat="server">
            <asp:HiddenField ID="hfAction" runat="server" />
            <div class="panel panel-block">
                <div class="panel-heading">
                    <h1 class="panel-title"><i class="fa fa-archive"></i>&nbsp;Import List</h1>
                </div>
                <div class="panel-body">
                    <asp:Panel ID="pnlList" runat="server" Visible="true">
                        <asp:Panel ID="pnlValues" runat="server">
                            <Rock:ModalAlert ID="mdGridWarningValues" runat="server" />
                            <div class="grid grid-panel">
                                <Rock:Grid ID="gImportList" runat="server" AllowPaging="false" DisplayType="Full" OnRowSelected="gImportList_Edit" AllowSorting="False">
                                    <Columns>
                                        <Rock:RockBoundField DataField="Name" HeaderText="Name" />
                                        <Rock:RockLiteralField ID="lImported" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" HeaderText="Imported" SortExpression="Person" />
                                        <Rock:RockLiteralField ID="lImportedPercentage" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" HeaderText="Imported Percentage" SortExpression="Imported Percentage" />
                                        <Rock:RockLiteralField ID="lDollars" HeaderText="Dollar Amount" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" SortExpression="Amount" />
                                        <Rock:RockLiteralField ID="lDollarsPercentage" HeaderText="Dollar Percentage" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" SortExpression="Amount" />
                                        <Rock:RockLiteralField HeaderText="Status" ID="lImportStatus" HeaderStyle-CssClass="grid-columnstatus" ItemStyle-CssClass="grid-columnstatus" FooterStyle-CssClass="grid-columnstatus" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" OnDataBound="lImportStatus_DataBound" />
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
