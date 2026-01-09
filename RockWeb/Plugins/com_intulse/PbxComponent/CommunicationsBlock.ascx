<%@ Control Language="C#" AutoEventWireup="true" CodeFile="CommunicationsBlock.ascx.cs" Inherits="RockWeb.Plugins.com_intulse.PbxComponent.CommunicationsBlock" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <section class="panel panel-persondetails">
            <div class="panel-heading clearfix">
                <h3 class="panel-title pull-left"><i class="fa fa-phone"></i> Intulse Communications</h3>
            </div>

            <Rock:NotificationBox ID="errorBox" runat="server" Visible="false" NotificationBoxType="Danger" Title="ERROR:" Text="There was an error while getting your communication history - try adjusting the date filter. If the problem persists please contact Intulse." />

            <div class="grid grid-panel">
                <%--TODO: With updated Rock version (> 9) GridFilter.cs gets the FieldLayout property, then we can use the following block of code--%>
                <%--<Rock:GridFilter ID="gridFilterCommunications" runat="server" OnApplyFilterClick="gridFilterCommunications_ApplyFilterClick" FieldLayout="Custom">
                    <div class="row">
                        <div class="col-md-2">
                            <Rock:DateRangePicker ID="filterDates" runat="server" Label="Date Range"  />
                        </div>
                        <div class="col-md-3">
                            <Rock:RockTextBox ID="filterName" runat="server" Label="Name"  />
                        </div>
                        <div class="col-md-3">
                            <Rock:RockTextBox ID="filterNumber" runat="server" Label="Number" />
                        </div>
                    </div>
                    <div class="row">
                        <div class="col-md-1">
                            <Rock:RockCheckBox ID="filterShowCdr" runat="server" Label="Show Calls" Checked="true" />
                        </div>
                        <div class="col-md-1">
                            <Rock:RockCheckBox ID="filterShowSms" runat="server" Label="Show SMS" Checked="true" />
                        </div>
                    </div>
                </Rock:GridFilter>--%>
                <Rock:GridFilter ID="gridFilterCommunications" runat="server" OnApplyFilterClick="gridFilterCommunications_ApplyFilterClick">
                    <Rock:DateRangePicker ID="filterDates" runat="server" Label="Date Range"  />
                    <Rock:RockTextBox ID="filterName" runat="server" Label="Name"  />
                    <Rock:RockTextBox ID="filterNumber" runat="server" Label="Number" />
                    <Rock:RockCheckBox ID="filterShowCdr" runat="server" Label="Show Calls" Checked="true" />
                    <Rock:RockCheckBox ID="filterShowSms" runat="server" Label="Show SMS" Checked="true" />
                </Rock:GridFilter>
                <Rock:Grid ID="gridCommunications" runat="server" AllowSorting="true" AllowPaging="true" DataKeyNames="CommunicationId" OnRowDataBound="gridCommunications_RowDataBound" RowItemText="Communication" RowStyle-Height="65px">
                    <Columns>
                        <Rock:RockTemplateField HeaderText="Date" SortExpression="CommunicationDateUtc" HeaderStyle-Width="100px" ItemStyle-Width="100px">
                            <ItemTemplate>
                                <div><%# ((com.intulse.PbxComponent.Models.CommunicationDisplay)Container.DataItem).CommunicationDateUtc.ToShortDateString() %></div>
                                <small><%# ((com.intulse.PbxComponent.Models.CommunicationDisplay)Container.DataItem).CommunicationDateUtc.ToShortTimeString() %></small>
                            </ItemTemplate>
                        </Rock:RockTemplateField>
                        <Rock:RockBoundField DataField="Type" HeaderText="Type" SortExpression="Type" HeaderStyle-Width="50px" ItemStyle-Width="50px" />
                        <Rock:RockTemplateField HeaderText="From" HeaderStyle-Width="20%">
                            <ItemTemplate>
                                <asp:Repeater ID="sourceRepeater" runat="server">
                                    <ItemTemplate>
                                        <div><%# Container.DataItem %></div>
                                    </ItemTemplate>
                                </asp:Repeater>
                            </ItemTemplate>
                        </Rock:RockTemplateField>
                        <Rock:RockTemplateField HeaderText="To" HeaderStyle-Width="20%">
                            <ItemTemplate>
                                <asp:Repeater ID="destinationRepeater" runat="server">
                                    <ItemTemplate>
                                        <div><%# Container.DataItem %></div>
                                    </ItemTemplate>
                                </asp:Repeater>
                            </ItemTemplate>
                        </Rock:RockTemplateField>
                        <Rock:RockTemplateField HeaderText="Message/Notes" >
                            <ItemTemplate>
                                <asp:Literal ID="communicationNoteLiteral" runat="server"></asp:Literal>
                            </ItemTemplate>
                        </Rock:RockTemplateField>
                        <Rock:EditField OnClick="gridCommunications_Edit" />
                        <Rock:RockTemplateField ID="recordingsContainer" HeaderText="Recordings" Headerstyle-Width="20%" HeaderStyle-HorizontalAlign="Right" ItemStyle-HorizontalAlign="Right">
                            <ItemTemplate>
                                <Rock:BootstrapButton ID="showRecordingsButton" runat="server" CssClass="btn btn-primary" OnCommand="loadRecordings">Load</Rock:BootstrapButton>
                                <asp:Literal ID="recordingsLiteral" runat="server"></asp:Literal>
                            </ItemTemplate>
                        </Rock:RockTemplateField>
                    </Columns>
                </Rock:Grid>
                <Rock:ModalDialog ID="noteModal" runat="server" Title="Edit Note" OnSaveClick="noteModal_Save">
                    <Content>
                        <fieldset>
                            <Rock:RockTextBox ID="noteModalTextbox" runat="server" TextMode="MultiLine" Rows="5" />
                            <asp:HiddenField ID="noteModalRowIndex" runat="server" />
                            <asp:HiddenField ID="noteModalCommunicationId" runat="server"/>
                        </fieldset>
                    </Content>
                </Rock:ModalDialog>
            </div>
        </section>
    </ContentTemplate>
</asp:UpdatePanel>