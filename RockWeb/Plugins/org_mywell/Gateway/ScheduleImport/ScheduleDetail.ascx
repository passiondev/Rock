<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ScheduleDetail.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ScheduleDetail" %>

<asp:UpdatePanel ID="upScheduleDetail" runat="server">
    <ContentTemplate>
        <asp:Panel ID="pnlDetails" CssClass="panel panel-block" runat="server">
            <asp:HiddenField ID="hfScheduleId" runat="server" />
            <asp:HiddenField ID="hfImportId" runat="server" />
            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-credit-card"></i>
                    Schedule Details
                </h1>
                <div class="panel-labels">
                    <asp:Literal ID="hlMyWellPortal" runat="server" />
                    <asp:Literal ID="lImportId" runat="server" />
                    <asp:Literal ID="lIsimported" runat="server" />
                    <asp:Literal ID="ltIsActive" runat="server" />
                    <Rock:HighlightLabel ID="hlType" runat="server" />
                </div>
            </div>
            <div class="panel-body">
                <Rock:NotificationBox ID="nbWarningMessage" runat="server" NotificationBoxType="Warning" />
                <fieldset id="fieldsetViewSummary" runat="server">
                    <Rock:NotificationBox ID="nbEditModeMessage" runat="server" NotificationBoxType="Info" />
                    <div class="row">
                        <div class="col-md-6">
                            <asp:Literal ID="lDetailsLeft" runat="server" />
                        </div>
                        <div class="col-md-6">
                            <asp:Literal ID="lDetailsRight" runat="server" />
                        </div>
                    </div>
                    <div id="pnlEditDetails" runat="server">
                        <asp:ValidationSummary ID="valSummarySchedule" runat="server" HeaderText="Please correct the following:" CssClass="alert alert-validation" />
                        <asp:CustomValidator ID="cvSchedule" runat="server" />

                        <div class="row">
                            <div class="col-md-6">
                                <div>
                                    <Rock:PersonPicker ID="ppSelectNew" Required="true" CssClass="js-matched-person" runat="server" Label="Assign Person" Help="Select a person to be matched to this schedule." IncludeBusinesses="true"  ExpandSearchOptions="true" />
                                </div>
                                <Rock:AccountPicker ID="apDisplayedPersonalAccounts" Required="true" runat="server" AllowMultiSelect="true" Label="Allocated Account" DisplayActiveOnly="true" />
                            </div>
                        </div>
                    </div>

                    <div class="actions">
                        <div class="pull-right">
                            <asp:LinkButton ID="btnUpdate" runat="server" Text="Edit" CssClass="btn btn-primary" CausesValidation="false" OnClick="lbEdit_Click" Visible="false" />
                            <asp:LinkButton ID="lbSave" runat="server" AccessKey="s" ToolTip="Alt+s" Text="Save" CssClass="btn btn-primary" OnClick="lbSave_Click" Visible="false" />
                            <asp:LinkButton ID="lbCancel" runat="server" AccessKey="c" ToolTip="Alt+c" Text="Cancel" CssClass="btn btn-link" CausesValidation="false" OnClick="lbCancel_Click" Visible="false" />
                        </div>
                        <div class="pull-right">
                            <asp:HyperLink ID="lbBack" runat="server" AccessKey="b" ToolTip="Alt+b" CssClass="btn btn-default margin-r-sm" OnClick="lbBack_Click"><i class="fa fa-chevron-left"></i> Back</asp:HyperLink>
                            <asp:HyperLink ID="lbNext" runat="server" AccessKey="n" ToolTip="Alt+n" CssClass="btn btn-default margin-r-sm">Next <i class="fa fa-chevron-right"></i></asp:HyperLink>
                        </div>
                    </div>
                </fieldset>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>
