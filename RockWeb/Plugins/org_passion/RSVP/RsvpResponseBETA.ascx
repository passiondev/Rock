<%@ Control Language="C#" AutoEventWireup="true" CodeFile="RsvpResponseBETA.ascx.cs" Inherits="RockWeb.Blocks.RSVP.RSVPResponse" %>

<asp:UpdatePanel ID="pnlContent" runat="server">
    <ContentTemplate>
    <!-- <div class="col-xs-12 col-sm-6 col-sm-offset-3"> -->
       <!-- <img ID="headerImage" src="https://connect.passion.team/GetImage.ashx?isBinaryFile=T&id=185421&fileName=ATM24_07_Team_Day_CONNECT_Header.png" style="width: 100%; padding-bottom: 10px;"> -->
        <div class="panel panel-default">

            <asp:Panel ID="pnlHeading" runat="server" CssClass="panel-heading">
                <h1 class="panel-title text-center">
                    <%--<i class="fa fa-user-check"></i>--%>
                    <asp:Literal ID="lHeading" runat="server" />
                </h1>
            </asp:Panel>
             
            <div class="panel-body">

                <Rock:NotificationBox ID="nbNotAuthorized" runat="server" Visible="false" Title="Sorry" NotificationBoxType="Warning" Text="You are not authorized to view this invitation." />
                <asp:Panel ID="pnl404" runat="server" Visible="false">
                    <Rock:NotificationBox ID="nbNotFound" runat="server" NotificationBoxType="Warning" Visible="false" Heading="Not Found">
                        Sorry, this RSVP could not be found.
                    </Rock:NotificationBox>
                    <Rock:NotificationBox ID="nbExpired" runat="server" NotificationBoxType="Warning" Visible="false">
                        Sorry, this event has reached capacity or is currently closed.
                    </Rock:NotificationBox>
                </asp:Panel>
               
                <asp:ValidationSummary ID="valSummary" runat="server" HeaderText="Please correct the following:" CssClass="alert alert-validation" />
                <Rock:NotificationBox ID="valDecline" runat="server" NotificationBoxType="Warning" Visible="false"/>
                <Rock:NotificationBox ID="valGuests" runat="server" NotificationBoxType="Warning" Visible="false"/>
                        
                    
                <asp:Panel ID="pnlForm" runat="server" Visible="false">
                    <div class="row">
                        <div class="col-xs-12 col-sm-6">
                            <Rock:RockTextBox ID="rtbFirstName" runat="server" Required="true" Label="First Name" />
                        </div>
                        <div class="col-xs-12 col-sm-6">
                            <Rock:RockTextBox ID="rtbLastName" runat="server" Required="true" Label="Last Name" />
                        </div>
                    </div>
                    <div class="row">
                        <div class="col-xs-12 col-sm-8 col-md-8">
                            <Rock:EmailBox ID="rebEmail" runat="server" Required="true" Label="Email Address" />
                        </div>
                        <!-- Make phone number conditional based on group attribute (can be changed in the cs file) -->
                        <div class="col-xs-12 col-sm-7 col-md-7">
                            <Rock:PhoneNumberBox ID="pnbPhone" runat="server" Required="false" Label="Cell Phone" Visible="false" />
                        </div>
                        <!-- ADD Marital Status element here -->
                        <div class="col-xs-12 col-sm-6 col-md-6">
                            <Rock:DefinedValuePicker ID="dvpMaritalStatus1" runat="server" Required="false" Label="Marital Status" DefinedTypeId="7" Visible="false" />
                        </div>
                    </div>
                    <div class="row">
                        <!-- ADD Gender element which will be conditional based on the group attribute (should be checked in cs file) -->
                        <div class="col-xs-12 col-sm-5 col-md-5">
                            <%-- PTP-18203: this was a Rock:DataDropDownList carrying no SourceTypeName or
                                 PropertyName. DataDropDownList.IsValid runs its DataAnnotationValidator
                                 unconditionally, and that throws "Null SourceTypeName can't be validated" when the
                                 pair is absent. RockControlHelper.RenderControl reads IsValid on every labeled
                                 control, so the page returned a 500 whenever this control rendered while visible --
                                 that is, any time lbAccept_Single_Click fails a check and returns instead of
                                 advancing: blank "Other" dietary text, an incomplete address, a bad birth date.
                                 RockDropDownList is what this static three-item list always wanted; it has no data
                                 validator. Adding SourceTypeName="Rock.Model.Person, Rock" PropertyName="Gender"
                                 would also stop the throw, but Person.Gender is [Required], so it would begin
                                 enforcing gender on every render -- a behavior change rather than a fix.
                                 RepeatDirection is dropped: a DropDownList has no such property, so it only ever
                                 rendered as a stray HTML attribute, left over from when this was a RadioButtonList
                                 (hence the "rbl" prefix, kept so the code-behind is untouched). --%>
                            <Rock:RockDropDownList ID="rblGender" runat="server" Required="false" Label="Gender" Visible="false" >
                                    <asp:ListItem Value="" />
                                    <asp:ListItem Text="Male" Value="1" />
                                    <asp:ListItem Text="Female" Value="2" />
                            </Rock:RockDropDownList>
                        </div>
                    </div>
                        <!-- ADD Birthdate element which will be conditional based on the group attribute (should be checked in cs file) -->
                    <div class="row">
                        <div class="col-xs-12 col-sm-4 col-md-4">
                            <Rock:DatePicker ID="dpBirthDate1" runat="server" Required="false" Label="Birth Date" AllowFutureDates="False" RequireYear="True" ShowOnFocus="false" StartView="decade" Visible="false" />
                        </div>
                        <!-- ADD address element which will be conditional based on the group attribute (should be checked in cs file) -->
                        
                        <div class="col-xs-12">
                            <Rock:AddressControl ID="acAddress" Label="Address" Required="false" runat="server" UseStateAbbreviation="true" UseCountryAbbreviation="false" Visible="false" />
                        </div>
                        
                    </div>

                </asp:Panel>
                
                <asp:Panel ID="pnlSingle_Choice" runat="server" Visible="false">
                    <div class="row">
                        <div class="col-sm-12">
                            <asp:PlaceHolder ID="phAttributes" runat="server" />
                        </div>
                    </div>
                    <div class="row">
                        <%-- PTP-18203: AutoPostBack on this picker tripped ASP.NET event validation, so every
                             checkbox click returned a 500. The "Other" box is revealed client-side now, so the
                             picker needs no postback and no OnSelectedIndexChanged handler.
                             rtbDietaryOther must NOT use Visible="false" -- a server-side hidden control renders
                             nothing at all, so script would have nothing to reveal. The wrapper div is hidden
                             instead, which keeps the input in the DOM and its value in ViewState.
                             pnlDietary is a PlaceHolder rather than a Panel so it emits no markup of its own and
                             does not break the Bootstrap "row > col-sm-12" structure. --%>
                        <asp:PlaceHolder ID="pnlDietary" runat="server" Visible="false">
                            <div class="col-sm-12 js-dietary-picker">
                                <Rock:DefinedValuesPicker ID="dvpDietaryRestrictions" runat="server" Label="Dietary Restrictions" Required="true" DefinedTypeId="346" RepeatColumns="1"/>
                            </div>
                            <div class="col-sm-12 js-dietary-other" style="display: none;">
                                <%-- Required is deliberately NOT set here. RockControlHelper re-forces
                                     RequiredFieldValidator.Enabled = true at render whenever Required is set
                                     (RockControlHelper.cs:191), which undoes any client-side ValidatorEnable(false).
                                     Because lbAccept_Single_Click never checks Page.IsValid, a hidden-but-required
                                     box let the RSVP save anyway while still rendering "Other is required." in the
                                     validation summary -- an error for a field the user could not even see.
                                     The requirement is enforced server-side in lbAccept_Single_Click instead, which
                                     is how this block already validates the birth date and address fields. --%>
                                <Rock:RockTextBox ID="rtbDietaryOther" runat="server" Label="Other" />
                            </div>
                        </asp:PlaceHolder>
                        <asp:PlaceHolder ID="divGuestCount" runat="server" Visible="false" >
                                    <h5 class="text-center mx-3">This Event Allows for Additional Guests, please include the number of guests you will be bringing (not including yourself) </h5>
                                <div class="col-xs-12 col-sm-8 col-md-6">
                                    <Rock:NumberBox ID="rnbGuestCount" runat="server" Required="false" Label="Additional Guests <a class='help' href='#' tabindex='-1' data-toggle='tooltip' data-placement='auto' data-container='body' data-html='true' title='' data-original-title='Only include the number of guests coming, not including yourself'><i class='fa fa-info-circle'></i></a>"/>
                                </div>
                            </asp:PlaceHolder>
                        <div class="col-sm-12"><hr style="opacity: .5;" /></div>
                    </div>
                    <div class="actions">
                        <asp:LinkButton ID="lbAccept_Single" runat="server" AccessKey="a" ToolTip="Alt+A" Text="Accept" CssClass="btn btn-primary form-group" OnClick="lbAccept_Single_Click"  />
                        <asp:LinkButton ID="lbDecline_Single" runat="server" AccessKey="d" ToolTip="Alt+D" Text="Decline" CssClass="btn btn-gray form-group" CausesValidation="false" OnClick="lbDecline_Single_Click" />
                    </div>
                </asp:Panel>

                <asp:Panel ID="pnlSingle_Accept" runat="server" Visible="false">
                    <Rock:NotificationBox ID="nbAccept" runat="server" NotificationBoxType="Info" />
                </asp:Panel>
                    

                <asp:Panel ID="pnlSingle_Decline" runat="server" Visible="false">
                    <div class="row">
                        <div class="col-sm-12">
                            <Rock:NotificationBox ID="nbDecline" runat="server" NotificationBoxType="Warning" />
                        </div>
                    </div>
                    <asp:Panel ID="pnlDeclineReasons" runat="server" Visible="false">
                        <div class="row">
                            <div class="col-sm-12">
                                <Rock:RockRadioButtonList ID="rrblDeclineReasons" runat="server" Label="Please enter a reason below:" Required="true" DataTextField="Value" DataValueField="Id" />
                            </div>
                        </div>
                        <div class="row">
                            <div class="col-sm-12">
                                <Rock:RockTextBox ID="rtbDeclineNote" runat="server" MaxLength="255" Label="Note" />
                            </div>
                        </div>
                        <div class="actions">
                            <asp:HiddenField ID="hfDeclineReason_OccurrenceId" runat="server" />
                            <asp:LinkButton ID="lbSaveDeclineReason" runat="server" AccessKey="s" ToolTip="Alt+S" Text="Save" CssClass="btn btn-primary" OnClick="lbSaveDeclineReason_Click" />
                        </div>
                    </asp:Panel>
                    <asp:Panel ID="pnlDeclineReasonConfirmation" runat="server" Visible="false">
                        <Rock:NotificationBox ID="nbDeclineReasonSaved" runat="server" NotificationBoxType="Success" Text="Saved." />
                    </asp:Panel>
                </asp:Panel>

                <asp:Panel ID="pnlMultiple_Choice" runat="server" Visible="false">

                    <asp:Repeater ID="rptrValues" runat="server" OnItemDataBound="rptrValues_ItemDataBound">
                        <ItemTemplate>
                            <div class="js-rsvp-item">
                                <article class="panel panel-widget checklist-item">
                                    <header class="panel-heading clearfix">
                                        <asp:HiddenField ID="hfOccurrenceId" runat="server" Value='<%# Eval("OccurrenceId") %>' />
                                        <Rock:RockCheckBox ID="rcbAccept" runat="server" Text='<%# Eval("Title") %>' CssClass="rsvp-list-input" />
                                    </header>
                                    <div class="checklist-description panel-body" style="display: none;">
                                        <asp:PlaceHolder ID="phOccurrenceAttributes" runat="server" />
                                    </div>
                                </article>
                            </div>
                        </ItemTemplate>
                    </asp:Repeater>
                    
                    <Rock:NotificationBox ID="nbNoOccurrencesSelected" runat="server" NotificationBoxType="Warning" Text="Please select at least one occurrence to accept." Visible="false" />
                    <div class="actions">
                        <asp:LinkButton ID="lbAccept_Multiple" runat="server" AccessKey="a" ToolTip="Alt+A" Text="Accept" CssClass="btn btn-primary" OnClick="lbAccept_Multiple_Click"  />
                    </div>
                </asp:Panel>
                <asp:Panel ID="pnlMultiple_Accept" runat="server" Visible="false">
                    <Rock:NotificationBox ID="nbAcceptMultiple" runat="server" NotificationBoxType="Success" />
                </asp:Panel>

            </div>

        </div>
    <!-- </div> -->
    </ContentTemplate>
</asp:UpdatePanel>
