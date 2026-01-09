<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ScheduleListMatching.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ScheduleListMatching" %>

<!-- <asp:LinkButton ID="lbActivateAll" Visible="true" runat="server" CssClass="btn btn-info" CausesValidation="false" OnClick="ReactivateSchedules_Click">Activate All Schedules<i class="fa fa-file-import ml-2"></i></asp:LinkButton> -->

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <script src="/SignalR/hubs"></script>
        <asp:HiddenField ID="hfBackNextHistory" runat="server" />
        <asp:HiddenField ID="hfHistoryPosition" runat="server" />
        <asp:HiddenField ID="hfScheduleId" runat="server" />
        <asp:HiddenField ID="hfImportId" runat="server" />
        <asp:HiddenField ID="hfDoFadeIn" runat="server" />
        <Rock:NotificationBox CssClass="mt-4" ID="nbImportNotFound" Visible="false" runat="server" NotificationBoxType="Warning" Text="<h3 class='mt-0 mb-0'><i class='fa fa-close mr-1'></i> Import does not exist</h3>" />
        <!-- Panel for importing from a previous gateway which will import all schedules one by one and cancel schedules from previous gateway-->
        <asp:Panel ID="pnlImportFromPreviousGateway" runat="server" CssClass="panel panel-block">
            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-archive"></i>
                    <asp:Literal ID="lImportTitle" runat="server"></asp:Literal>
                </h1>
            </div>
            <div class="panel-body">
                <div style="margin: 0 auto; width: 690px; max-width: 100%;">
                    <!-- Confirm import from and to gateways -->
                    <div class="text-center">
                        <asp:Image ID="imgMyWellLogo" CssClass="width-half margin-b-lg margin-t-lg" runat="server" />
                        <asp:Literal ID="lImportDescription" runat="server"></asp:Literal>
                        <div class="margin-t-lg">
                            <asp:Literal ID="lMigratingToGateway" runat="server"></asp:Literal>
                        </div>
                        <div class="margin-t-md">
                            <asp:Literal ID="lPreviousGateway" runat="server"></asp:Literal>
                        </div>
                    </div>
                    <!-- Import complete message-->
                    <asp:Panel ID="pnlDone" runat="server" CssClass="panel-body js-messageContainer mt-4" Style="display: none">
                        <div class="alert alert-success shadow-lg mb-0">
                            <asp:Literal ID="ltCompleteTitle" Text="<h4>Import Complete</h4>" runat="server"></asp:Literal>
                            <pre><asp:Label ID="lDone" CssClass="js-progressResults" runat="server" /></pre>
                            <asp:Literal ID="lViewImport" runat="server"></asp:Literal>
                        </div>
                    </asp:Panel>
                    <!-- Progress Message-->
                    <asp:Panel ID="pnlProgress" runat="server" CssClass="panel-body js-messageContainer mt-4" Visible="false">
                        <div class="alert alert-warning shadow-lg mb-0">
                            <asp:Literal ID="ltProgressTitle" Text="<h4>Importing Schedules</h4>" runat="server"></asp:Literal>
                            <asp:Label ID="lProgressMessage" CssClass="js-progressMessage" runat="server" Text="Loading..." />
                        </div>
                    </asp:Panel>
                    <!-- Error message-->
                    <asp:Panel ID="pnlError" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                        <div class="alert alert-danger shadow-lg mb-0">
                            <h4>Import Errors: </h4>
                            <pre><asp:Label ID="lError" CssClass="js-progressResults" runat="server" /></pre>
                        </div>
                    </asp:Panel>
                    <!-- Import button-->
                    <div class="text-center margin-t-xl">
                        <asp:LinkButton ID="btnImportFromPreviousGateway" runat="server" CssClass="btn btn-primary" Text="Import" OnClick="btnImportFromPreviousGateway_Click" />
                    </div>
                    <!-- Retry Cancellation button-->
                    <div class="text-center mt-5">
                        <asp:Literal ID="lFailedCancellationDescription" Visible="false" runat="server"></asp:Literal>
                    </div>
                    <div class="text-center margin-t-xl">
                        <asp:LinkButton ID="btnCancelSchedules" Visible="false" runat="server" CssClass="btn btn-danger" Text="Cancel Schedules" OnClick="btnCancelSchedules_Click" />
                    </div>
                    <!-- My Well link -->
                    <div class="text-center margin-t-lg margin-b-lg">
                        <a href="https://www.mywell.org">https://www.mywell.org</a>
                    </div>
                </div>
            </div>
        </asp:Panel>

        <!-- Matching Schedule Panel -->
        <asp:Panel ID="pnlView" runat="server" CssClass="">
            <!-- Allow full screen -->
            <div class="d-flex pb-4 align-items-center justify-content-end">
                <asp:LinkButton ID="btnFilter" runat="server" CssClass="btn btn-xs btn-square btn-default mr-3" OnClick="btnFilter_Click"><i class="fa fa-gear" title="Filter Accounts"></i></asp:LinkButton>
                <div class="mywell-fullscreen-toggle js-fullscreen-trigger"></div>
            </div>
            <!-- Progress bar -->
            <div class="bg-white shadow-xl p-1 rounded-lg pb-2 pl-4 pr-4 mb-4">
                <asp:Literal ID="lProgressBar" runat="server"></asp:Literal>
            </div>
            <%-- All schedules imported message --%>
            <asp:Panel ID="plnComplete" runat="server" Visible="false">
                <div class="alert alert-success shadow-lg">
                    <asp:Literal ID="nbNoUnmatchedTransactionsRemaining" runat="server" Text="<h3 class='mt-2'><i class='fa fa-check-circle mr-2 text-green-500'></i> All schedules were successfully matched!</h3>" />
                    <div class="actions">
                        <asp:LinkButton ID="lbFinish" runat="server" CssClass="btn btn-success mb-2 mt-1" OnClick="lbFinish_Click">Done</asp:LinkButton>
                    </div>
                </div>
            </asp:Panel>
            <%-- All schedules imported message --%>
            <asp:Panel ID="plnContent" runat="server">
                <div class="bg-white shadow-xl p-1 rounded-lg pb-2 pl-4 pr-4 mb-4">
                    <!--Schedule Details Panel-->
                    <asp:Panel ID="pnlScheduleDetails" runat="server">
                        <div style="border-bottom: 1px solid #e6e6e6">
                            <div class="row">
                                <div class="col-md-12 transaction-matching-details">
                                    <div class="header">
                                        <h3>Schedule Details</h3>
                                        <div class="row">
                                            <div class="col-md-4">
                                                <asp:Literal ID="lDetailsRight" runat="server" />
                                            </div>
                                            <div class="col-md-4">
                                                <asp:Literal ID="LDetatilsCenter" runat="server" />
                                            </div>
                                            <div class="col-md-4">
                                                <asp:Literal ID="LDetatilsLeft" runat="server" />
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </asp:Panel>
                    <!--Match the schedule to a person and account-->
                    <asp:Panel ID="pMatchSchedule" runat="server">
                        <div class="row mt-4">
                            <div class="col-md-6">
                                <div>
                                    <Rock:PersonPicker ID="ppSelectNew" CssClass="js-matched-person" runat="server" Label="Assign Person" Help="Select a person to be matched to this schedule." IncludeBusinesses="true" OnSelectPerson="ppSelectNew_SelectPerson" ExpandSearchOptions="true" />
                                </div>
                                <asp:Panel ID="pnlPreview" CssClass="contents" runat="server">
                                    <dl>
                                        <asp:Literal ID="lPersonName" runat="server" />
                                        <asp:Literal ID="lCampus" runat="server" />
                                    </dl>
                                    <!-- List of addresses associated with this person -->
                                    <div class="list-unstyled">
                                        <asp:Repeater ID="rptrAddresses" runat="server">
                                            <ItemTemplate>
                                                <dl class="address clearfix">
                                                    <dt><%# Eval("GroupLocationTypeValue.Value") %></dt>
                                                    <dd>
                                                        <%# Eval("Location.FormattedHtmlAddress") %>
                                                    </dd>
                                                </dl>
                                            </ItemTemplate>
                                        </asp:Repeater>
                                    </div>
                                    <div class="list-unstyled address-extended" style="display: none">
                                        <asp:Repeater ID="rptPrevAddresses" runat="server">
                                            <ItemTemplate>
                                                <dl class="address clearfix">

                                                    <dt><%# Eval("GroupLocationTypeValue.Value") %></dt>
                                                    <dd>
                                                        <%# Eval("Location.FormattedHtmlAddress") %>
                                                    </dd>
                                                </dl>
                                            </ItemTemplate>
                                        </asp:Repeater>
                                    </div>
                                    <ul class="list-unstyled">
                                        <li>
                                            <a class="js-address-toggle btn btn-xs btn-link" id="btnMoreAddress" title="Show additional addresses" visible="false" runat="server">Show More</a>
                                        </li>
                                    </ul>
                                </asp:Panel>
                            </div>
                            <!-- Show accounts -->
                            <div id="account_entry" class="col-md-6 body">
                                <Rock:RockControlWrapper ID="rcwAccountSplit" runat="server">
                                    <div class="form-horizontal label-auto js-accounts">
                                        <asp:Repeater ID="rptAccounts" runat="server">
                                            <ItemTemplate>
                                                <Rock:CurrencyBox ID="cbAccountAmount" runat="server" Label='<%#Eval( "Name" )%>' data-account-id='<%#Eval("Id")%>' CssClass="js-account-amount input-width-md" onkeydown="javascript:return handleAmountBoxKeyPress(this, event.keyCode);" onkeyup="javascript:handleAmountBoxKeyUp(event.keyCode)" />
                                            </ItemTemplate>
                                        </asp:Repeater>
                                    </div>
                                </Rock:RockControlWrapper>
                                <div class="mt-5 pull-right mb-2">
                                    <Rock:CurrencyBox ID="cbUnallocatedAmount" runat="server" Label="Unallocated Amount" CssClass="input-width-lg js-unallocated-amount has-error" Help="The unallocated amount based on the original total amount." disabled="disabled" />
                                    <Rock:CurrencyBox ID="cbTotalAmount" runat="server" Label="Total Amount" CssClass="js-total-amount input-width-lg" Help="Allocates amounts to the above account(s) until the total amount matches what is shown on the transaction image." disabled="disabled" Text="0.00"></Rock:CurrencyBox>
                                    <Rock:HiddenFieldWithClass ID="hfOriginalTotalAmount" runat="server" CssClass="js-original-total-amount" />
                                    <Rock:HiddenFieldWithClass ID="hfCurrencySymbol" runat="server" CssClass="js-currencysymbol" />
                                </div>
                            </div>
                        </div>
                    </asp:Panel>
                    <!-- Show any error messages -->
                    <div class="footer">
                        <Rock:NotificationBox ID="nbSaveError" CssClass="mt-3" runat="server" NotificationBoxType="Danger" Dismissable="true" Text="Warning. Unable to import..." />
                    </div>
                </div>
                <!-- Action Buttons-->
                <asp:Panel ID="pActionButtons" runat="server">
                    <div class="actions mt-4 mb-5">
                        <asp:LinkButton ID="btnCancel" runat="server" CssClass="btn btn-default pull-left" Visible="true" OnClick="btnCancel_Click">Cancel</asp:LinkButton>
                        <asp:LinkButton ID="btnNext" runat="server" AccessKey="n" ToolTip="Alt+n" CssClass="btn btn-primary pull-right" OnClick="btnNext_Click">Import Schedule <i class="fa fa-chevron-right"></i></asp:LinkButton>
                    </div>
                </asp:Panel>
                <!-- Account selector modal -->
                <Rock:ModalDialog ID="mdAccountsPersonalFilter" runat="server" Title="Accounts Filter" OnSaveClick="mdAccountsPersonalFilter_SaveClick">
                    <Content>
                        <div class="row">
                            <div class="col-sm-6">
                                <Rock:AccountPicker ID="apDisplayedPersonalAccounts" runat="server" AllowMultiSelect="true" Label="Displayed Accounts" DisplayActiveOnly="true" />
                            </div>
                        </div>
                    </Content>
                </Rock:ModalDialog>
            </asp:Panel>
        </asp:Panel>

        <script>
            // update the Total Amount UI text as amounts are edited
            function updateRemainingAccountAllocation() {
                // do currency math in Cents instead of Dollars to avoid floating point math issues
                var transactionTotalAmountCents = null;

                $('#<%=pnlView.ClientID%> .js-account-amount :input').each(function (index, elem) {
                    var accountAmountDollar = $(elem).val();
                    if (!isNaN(accountAmountDollar) && accountAmountDollar != "") {
                        transactionTotalAmountCents = (transactionTotalAmountCents || 0.00) + Number(accountAmountDollar) * 100;
                    }
                });

                var transactionTotalAmountDollars = transactionTotalAmountCents != null ? (transactionTotalAmountCents / 100).toFixed(2) : null;

                $('#<%=pnlView.ClientID%>').find('.js-total-amount :input').val(transactionTotalAmountDollars);

                $unallocatedAmountEl = $('#<%=pnlView.ClientID%>').find('.js-unallocated-amount');

                var originalTotalAmountCents = Number($('#<%=pnlView.ClientID%>').find('.js-original-total-amount').val());
                var unallocatedAmountCents = 0;
                if (originalTotalAmountCents && originalTotalAmountCents > 0) {
                    unallocatedAmountCents = originalTotalAmountCents - (transactionTotalAmountCents || 0);
                }

                $unallocatedAmountEl.find(':input').val((unallocatedAmountCents / 100).toFixed(2));
                if (Math.round(unallocatedAmountCents) == 0) {
                    $unallocatedAmountEl.hide();
                }
                else {
                    $unallocatedAmountEl.show();
                }

            }

            Sys.Application.add_load(function () {
                Rock.controls.fullScreen.initialize();

                if ($('#<%=hfDoFadeIn.ClientID%>').val() == "1") {
                    $('#<%=pnlView.ClientID%>').rockFadeIn();
                }

                var $buttonNext = $('#<%=btnNext.ClientID%>');

                $buttonNext.on('click', function (e) {
                    var successLocation = $buttonNext.prop('href');
                    navigateNext(e, successLocation);
                });

                updateRemainingAccountAllocation();

                $('.js-address-toggle').on('click', function (e) {
                    if (e && e.preventDefault) {
                        e.preventDefault();
                    }
                    else if (e) {
                        e.returnValue = false;
                    }
                    var link = $(this);

                    $('.address-extended').slideToggle(function () {
                        if ($(this).is(':visible')) {
                            link.text('Show Less').prop('title', 'Hide additional addresses');
                        } else {
                            link.text('Show More').prop('title', 'Show additional addresses');
                        }
                    });
                });

                // sort the amount boxes in the order that they were added
                $('.js-accounts .currency-box').detach().sort(function (a, b) {
                    var sortA = $(a).find("input").data("sort-order");
                    var sortB = $(b).find("input").data("sort-order");
                    if (sortA < sortB)
                        return -1
                    if (sortA > sortB)
                        return 1
                    return 0;

                }).appendTo('.js-accounts');

            })

            // handle onkeypress for the account amount input boxes
            function handleAmountBoxKeyPress(element, keyCode) {
                // if Enter was pressed when in one of the Amount boxes, click the Next button.
                if (keyCode == 13) {
                    var successLocation = $('#<%=btnNext.ClientID%>').prop('href');
                    if (navigateNext(null, successLocation)) {
                        return true;
                    }
                    return false;
                }
                else if (keyCode == 40) {
                    // pressing the down arrow goes to the next input or to the Next button
                    var clientId = element.getAttribute('id');
                    // find the "next" textbox
                    var textbox = $('#' + clientId).parent().parent().parent().next().find('input');
                    if (textbox.length != 0) {
                        textbox.focus();
                    }
                    else {
                        $('#<%=btnNext.ClientID%>').focus();
                    }
                }
                else if (keyCode == 38) {
                    // pressing the up arrow goes to the previous input
                    var clientId = element.getAttribute('id');
                    // find the "previous" textbox
                    var textbox = $('#' + clientId).parent().parent().parent().prev().find('input');
                    if (textbox.length != 0) {
                        textbox.focus();
                    }
                }
            }

            // handle onkeyup for the account amount input boxes
            function handleAmountBoxKeyUp(keyCode) {
                updateRemainingAccountAllocation();
            }

            /**
             *  returns true if the amount was changed from the original(if there was an amount to start with)
             */
            function hasUnallocated() {
                $unallocatedAmountEl = $('#<%=pnlView.ClientID%>').find('.js-unallocated-amount');
                if ($unallocatedAmountEl.is(':visible')) {
                    if (Number($unallocatedAmountEl.find('input').val()) != 0) {
                        return true;
                    }
                }

                return false;
            }

            /**
             * handle btnNext (or KeyPress on amount)
             * if the amount was changed from the original(if there was an amount to start with) it will ask for confirmation before navigating.
             * @param successLocation the Postback javascript if navigation is allowed
            */
            function navigateNext(e, successLocation) {
                if (hasUnallocated()) {
                    if (e) {
                        e.preventDefault();
                    }

                    var originalTotalAmountCents = Number($('#<%=pnlView.ClientID%>').find('.js-original-total-amount').val());
                    var totalAmountCents = Number($('#<%=pnlView.ClientID%>').find('.js-total-amount :input').val()) * 100;
                    var currencySymbol = $('#<%=pnlView.ClientID%>').find('.js-currencysymbol').val()
                    var warningMsg = 'The original schedule amount is ' + currencySymbol + (originalTotalAmountCents / 100).toFixed(2) + '. You have allocated ' + currencySymbol + (totalAmountCents / 100).toFixed(2) + '. Please fix this before importing the schedule.';
                    Rock.dialogs.alert(warningMsg, function (result) {
                        if (result && successLocation) {
                            // do the Postback (which will save the changes)
                            window.location = successLocation;
                        }
                    });
                }

                else {

                    // do the Postback (which will save the changes)
                    window.location = successLocation;
                }
            }

            $(function () {
                var proxy = $.connection.rockMessageHub;
                proxy.client.receiveNotification = function (name, status) {
                    if (name == '<%=this.SignalRNotificationKey %>') {
                        if (status) {
                            $('#<%=lProgressMessage.ClientID %>').html(status);
                        }
                    }
                }
                proxy.client.error = function (name, errorText) {
                    if (name == '<%=this.SignalRNotificationKey %>') {
                        $('#<%=pnlError.ClientID%>').show();
                        $('#<%=lError.ClientID %>').html(errorText);
                    }
                }

                proxy.client.done = function (name, message) {
                    if (name == '<%=this.SignalRNotificationKey %>') {
                        $('#<%=pnlError.ClientID%>').hide();
                        $('#<%=pnlProgress.ClientID%>').hide();
                        $('#<%=pnlDone.ClientID%>').show();
                        $('#<%=lDone.ClientID %>').html(message);
                    }
                }
                $.connection.hub.start().done(function () {

                });
            })

        </script>
    </ContentTemplate>
</asp:UpdatePanel>
<style>
    .mywell-fullscreen-toggle {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 50px;
        padding: 0 10px;
        line-height: 40px;
        color: #303030;
        text-align: center;
        cursor: pointer;
        border-left: 1px solid #cbcbcb;
        opacity: 0.5;
        transition: 0.2s;
    }

        .mywell-fullscreen-toggle::before {
            font-family: 'FontAwesome';
            font-weight: 900;
            text-align: center;
            content: "\f065";
        }

        .mywell-fullscreen-toggle:hover {
            font-size: 110%;
            color: #343a40;
            opacity: 0.75;
        }
</style>
