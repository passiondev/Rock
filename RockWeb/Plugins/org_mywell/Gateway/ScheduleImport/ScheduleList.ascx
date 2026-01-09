<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ScheduleList.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ScheduleList" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <asp:Panel ID="pnlImportList" runat="server">
            <asp:HiddenField ID="hfImportId" runat="server" />
            <asp:HiddenField ID="hfAction" runat="server" />
            <div class="panel panel-block">
                <div class="panel-heading">
                    <h1 class="panel-title"><i class="fa fa-archive"></i>&nbsp;Schedule List</h1>
                </div>
                <div class="panel-body">
                    <asp:Panel ID="pnlList" runat="server" Visible="true">
                        <asp:Panel ID="pnlValues" runat="server">
                            <Rock:ModalAlert ID="mdGridWarningValues" runat="server" />
                            <asp:HiddenField ID="hfScheduleViewMode" runat="server" />
                            <div class="grid grid-panel">
                                <!--Filters for Import screen -->
                                <Rock:GridFilter ID="gfImportSettings" runat="server">
                                    <Rock:RockDropDownList ID="dvpImportFrequency" runat="server" Label="Frequency">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:RockDropDownList ID="ddlImportStatus" runat="server" Label="Status">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:RockTextBox ID="tbImportScheduleId" runat="server" Label="Schedule Id"></Rock:RockTextBox>
                                    <Rock:RockDropDownList ID="dvpImportCurrencyType" runat="server" Label="Currency Type">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:DefinedValuePicker ID="dvpImportCreditCardType" runat="server" Label="Credit Card Type" />
                                    <Rock:RockTextBox ID="tbImportPreviousScheduleId" runat="server" Label="Previous Schedule Id"></Rock:RockTextBox>
                                </Rock:GridFilter>
                                <!--Filters for Activation screen -->
                                <Rock:GridFilter ID="gfActivationSettings" runat="server">
                                    <Rock:RockDropDownList ID="dvpActivationFrequency" runat="server" Label="Frequency">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:RockDropDownList ID="ddlActivationStatus" runat="server" Label="Status">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:RockTextBox ID="tbActivationScheduleId" runat="server" Label="Schedule Id"></Rock:RockTextBox>
                                    <Rock:RockDropDownList ID="dvpActivationCurrencyType" runat="server" Label="Currency Type">
                                        <asp:ListItem Text="" Value=""></asp:ListItem>
                                    </Rock:RockDropDownList>
                                    <Rock:DefinedValuePicker ID="dvpActivationCreditCardType" runat="server" Label="Credit Card Type" />
                                    <Rock:DateRangePicker ID="drpActivatedDates" runat="server" Label="Activated" />
                                    <Rock:RockTextBox ID="tbActivationPreviousScheduleId" runat="server" Label="Previous Schedule Id"></Rock:RockTextBox>
                                </Rock:GridFilter>
                                <Rock:Grid ID="gImportList" runat="server" AllowPaging="true" DisplayType="Full" OnRowSelected="gImportList_Edit" AllowSorting="True" ExportSource="ColumnOutput">
                                    <Columns>
                                        <Rock:SelectField ItemStyle-Width="48px" />
                                        <Rock:RockLiteralField ID="lPerson" HeaderText="Person" SortExpression="Person" />
                                        <Rock:RockLiteralField ID="lTotalAmount" HeaderText="Amount" ItemStyle-HorizontalAlign="Right" HeaderStyle-HorizontalAlign="Right" SortExpression="Amount" />
                                        <Rock:DefinedValueField DataField="TransactionFrequencyValueId" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" HeaderText="Frequency" SortExpression="TransactionFrequencyValueId" />
                                        <Rock:DateField DataField="StartDate" HeaderText="Start Date" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" SortExpression="StartDate" />
                                        <Rock:DefinedValueField DataField="CurrencyTypeValueId" HeaderText="Currency Type" />
                                        <Rock:RockBoundField DataField="GatewayScheduleId" HeaderText="Schedule ID" />
                                        <Rock:RockBoundField DataField="PreviousGatewayScheduleId" HeaderText="Previous Schedule ID" />
                                        <Rock:DateField DataField="ActivatedDateTime" HeaderText="Activated Date" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" SortExpression="ActivatedDateTime" />
                                        <Rock:RockLiteralField HeaderText="Status" ID="lImportStatus" HeaderStyle-CssClass="grid-columnstatus" ItemStyle-CssClass="grid-columnstatus" FooterStyle-CssClass="grid-columnstatus" ItemStyle-HorizontalAlign="Center" HeaderStyle-HorizontalAlign="Center" OnDataBound="lImportStatus_DataBound" SortExpression="IsImported" ExcelExportBehavior="AlwaysInclude" />
                                        <%-- Fields that are only shown when exporting --%>
                                        <Rock:DefinedValueField DataField="CreditCardTypeValueId" HeaderText="Credit Card Type" Visible="false" ExcelExportBehavior="AlwaysInclude" />
                                        <%-- Fields that we dont need when exporting --%>
                                        <Rock:DefinedValueField DataField="IsImported" HeaderText="Is Imported" Visible="false" ExcelExportBehavior="NeverInclude" />
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
