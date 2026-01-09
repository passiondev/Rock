<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ImportDetail.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ImportDetail" %>

<script src="/SignalR/hubs"></script>
<script type="text/javascript">
    $(function () {
        var proxy = $.connection.rockMessageHub;
        proxy.client.receiveNotification = function (name, status) {
            if (name == '<%=this.SignalRNotificationKey %>') {
                if (status) {
                    $('#<%=lProgressMessage.ClientID %>').html(status);
                    $('#<%=lActivationProgressMessage.ClientID %>').html(status);
                }
            }
        }
        proxy.client.error = function (name, errorText) {
            if (name == '<%=this.SignalRNotificationKey %>') {
                $('#<%=pnlError.ClientID%>').show();
                $('#<%=pnlActivationError.ClientID%>').show();
                $('#<%=lError.ClientID %>').html(errorText);
                $('#<%=lActivationErrorMessage.ClientID %>').html(errorText);
            }
        }

        proxy.client.done = function (name, message, redirectUrl) {
            if (name == '<%=this.SignalRNotificationKey %>') {
                $('#<%=pnlError.ClientID%>').hide();
                $('#<%=pnlProgress.ClientID%>').hide();
                $('#<%=pnlActivationError.ClientID%>').hide();
                $('#<%=pnlActivationProgress.ClientID%>').hide();
                $('#<%=pnlDone.ClientID%>').show();
                $('#<%=lDone.ClientID %>').html(message);
                $('#<%=hfImportId.ClientID%>').val(redirectUrl);

            }
        }
        $.connection.hub.start().done(function () {

        });
    })
</script>
<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <asp:HiddenField ID="hfImportId" runat="server" />
        <asp:Panel ID="pnlDetails" runat="server">
            <!--Buttons on Top of Page to the portal and to match/activate schedules-->
            <fieldset id="fieldsetViewSummary" class="mb-4" runat="server">
                <div class="pull-right">
                    <asp:LinkButton ID="lbImportSchedules" Visible="false" runat="server" CssClass="btn btn-info" CausesValidation="false" OnClick="lbImportSchedules_Click">Import Schedules<i class="fa fa-file-import ml-2"></i></asp:LinkButton>
                    <asp:LinkButton ID="lbMatch" Visible="false" runat="server" CssClass="btn btn-info" CausesValidation="false" OnClick="lbMatch_Click"> Match & Import Schedules<i class="fa fa-file-import ml-2"></i></asp:LinkButton>
                    <asp:LinkButton ID="lbActivateSchedules" Visible="false" runat="server" CssClass="btn btn-success" CausesValidation="false" OnClick="lbActivateSchedules_Click">Activate<i class="fa fa-check-circle ml-2"></i></asp:LinkButton>
                </div>
                <div>
                    <a runat="server" class="btn btn-default" id="lbMyWellPortal">My Well Portal<i class="fa fa-arrow-circle-o-right ml-2"></i></a>
                </div>
            </fieldset>
            <!--Show successful message when schedules are activated after matching schedules to person/account-->
            <asp:Panel ID="pnSuccessMessage" Visible="false" runat="server">
                <div class="alert alert-success shadow-lg p-4 mb-4">
                    <h3 class="mt-0">
                        <asp:Label ID="lbSchedulesActivated" runat="server" Text="<i class='fa fa-check-circle mr-2 text-green-500'></i>Schedules Activated"></asp:Label>
                    </h3>
                    <p>
                        <asp:Label ID="lbSuccessMessageBody" runat="server" Text="Imported schedules are all <strong>Active</strong> in Rock." />
                    </p>
                </div>
            </asp:Panel>
            <!--Errors that happen during activation of schedules -->
            <asp:Panel ID="pnErrorMessage" Visible="false" runat="server">
                <div class="alert alert-danger rounded-lg shadow-lg">
                    <h3 class="mt-0">
                        <asp:Label ID="lErrorMessageTitle" runat="server"></asp:Label>
                    </h3>
                    <p>
                        <asp:Label ID="lErrorBody" runat="server" />
                    </p>
                </div>
            </asp:Panel>
            <!-- Request user to activate schedules after matching all schedules-->
            <asp:Panel ID="pnlWarningMessage" Visible="false" runat="server">
                <div class="alert alert-warning p-4 shadow-lg">
                    <h3 class="mt-0">
                        <asp:Label ID="lWarningMessageTitle" runat="server" Text="<i class='fa fa-exclamation-triangle mr-2 text-yello-500'></i> Activate Schedules!"></asp:Label>
                    </h3>
                    <p>
                        <asp:Label ID="lWarning" runat="server" Text="Imported schedules are temporarily <strong>INACTIVE</strong> in Rock. The user will not see the imported schedule until you press <strong>Activate</strong>." />
                    <p>
                </div>
            </asp:Panel>

            <asp:Panel ID="pnlActivationProgress" runat="server" CssClass="panel-body js-messageContainer p-0 pb-5" Visible="false">
                <div class="alert alert-info shadow-lg mb-0">
                    <h4>Status:</h4>
                    <pre> <asp:Label ID="lActivationProgressMessage" CssClass="js-progressResults" runat="server" Text="Loading..." /></pre>
                </div>
            </asp:Panel>

            <!-- Error message-->
            <asp:Panel ID="pnlActivationError" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                <div class="alert alert-danger shadow-lg mb-0">
                    <h4>Import Errors: </h4>
                    <pre><asp:Label ID="lActivationErrorMessage" CssClass="js-progressResults" runat="server" /></pre>
                </div>
            </asp:Panel>

            <!-- Show navigation only for partial schedules. Will show Import status and Activation Status. -->
            <asp:Panel ID="pnlNavigation" Visible="false" runat="server">
                <asp:HiddenField ID="hfImportViewMode" runat="server" />
                <div class="d-flex flex-row mb-4 pt-3">
                    <asp:LinkButton ID="lbImportLink" runat="server" CssClass="mywell-link mywell-link-active" CausesValidation="false" OnClick="btnImportViewMode_Click">Import Status</asp:LinkButton>
                    <asp:LinkButton ID="lbClaimedLink" runat="server" CssClass="mywell-link" CausesValidation="false" OnClick="btnImportViewMode_Click">Activation Status</asp:LinkButton>
                </div>
            </asp:Panel>
            <div class="row">
                <div class="col-sm-6 mb-4 pb-2">
                    <!-- Metrics for number of schedules imported  -->
                    <div class="rounded-lg bg-white pl-4 pt-4 pr-4 shadow-lg pb-5">
                        <div class="d-flex flex-row mb-3">
                            <div style="width: 60px" class="bg-blue-100 mywell-icon-container-activated rounded-circle d-flex flex-row"><i class="text-blue-500 w-100 d-flex flex-row align-items-center justify-content-center fa fa-calendar-alt fa-2x"></i></div>
                            <asp:Literal ID="ltSchedulesImported" runat="server"></asp:Literal>
                        </div>
                        <asp:Literal ID="lProgressBar" runat="server"></asp:Literal>
                        <div class="pull-right">
                            <asp:Literal ID="ltSchedulesNotImported" runat="server"></asp:Literal>
                        </div>
                    </div>
                </div>
                <!-- Metrics for dollar amount of schedules imported  -->
                <div class="col-sm-6 mb-4 pb-2">
                    <div class="rounded-lg bg-white pl-4 pt-4 pr-4 pb-5 shadow-lg">
                        <div class="d-flex flex-row mb-3">
                            <div style="width: 60px" class="bg-green-100 mywell-icon-container-activated rounded-circle d-flex flex-row"><i class="text-green-500 w-100 d-flex flex-row align-items-center justify-content-center fa fa-dollar-sign fa-2x"></i></div>
                            <asp:Literal ID="ltSchedulesImportDollarAmount" runat="server"></asp:Literal>
                        </div>
                        <asp:Literal ID="lProgressBarDollars" runat="server"></asp:Literal>
                        <div class="pull-right">
                            <asp:Literal ID="ltSchedulesNotImportDollarAmount" runat="server"></asp:Literal>
                        </div>
                    </div>
                </div>
            </div>
            <!-- Show the metrics for activated by frequency -->
            <asp:HiddenField ID="hfFrequencyViewMode" runat="server" />
            <div class="row mb-4">
                <div class="col-sm-12">
                    <div class="rounded-lg bg-white pl-4 pr-4 pt-1 shadow-lg pb-3">
                        <div class="row">
                            <div class="col-sm-12 mb-2 d-flex align-items-center" style="justify-content: space-between;">
                                <asp:Literal runat="server" ID="litFrequencyTitle"></asp:Literal>

                                <div class="btn-group panel-toggle pull-right">
                                    <asp:LinkButton ID="btnFrequencyTotal" CssClass="btn btn-xs btn-info" runat="server" OnClick="btnFrequencyViewMode_Click"><i class="fa fa-calendar"></i></asp:LinkButton>
                                    <asp:LinkButton ID="btnFrequencyDollars" CssClass="btn btn-xs btn-outline-success" runat="server" OnClick="btnFrequencyViewMode_Click"><i class="fa fa-dollar-sign"></i></asp:LinkButton>
                                </div>
                            </div>
                        </div>
                        <div class="row">
                            <asp:Literal ID="lProgressFrequency" runat="server" />
                        </div>
                    </div>
                </div>
            </div>
        </asp:Panel>
        <asp:Panel ID="pnlUpload" CssClass="panel panel-block" runat="server">
            <!-- Show the heading of upload screen -->
            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-archive"></i>
                    <asp:Literal ID="lTitle" runat="server" />
                </h1>
                <div class="panel-labels">
                    <Rock:HighlightLabel ID="hlStatus" runat="server" />
                </div>
            </div>
            <Rock:PanelDrawer ID="pdAuditDetails" runat="server"></Rock:PanelDrawer>
            <!-- Request user to upload the csv and fill out required fields -->
            <div class="panel-body">
                <asp:Panel ID="pnlProgress" runat="server" CssClass="panel-body js-messageContainer" Visible="false">
                    <div class="alert alert-info shadow-lg mb-0">
                        <h4>Status:</h4>
                        <pre> <asp:Label ID="lProgressMessage" CssClass="js-progressResults" runat="server" Text="Loading..." /></pre>
                    </div>
                </asp:Panel>

                <!-- Error message-->
                <asp:Panel ID="pnlError" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                    <div class="alert alert-danger shadow-lg mb-0">
                        <h4>Import Errors: </h4>
                        <pre><asp:Label ID="lError" CssClass="js-progressResults" runat="server" /></pre>
                    </div>
                </asp:Panel>

                <asp:Panel ID="pnlDone" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                    <div class="alert alert-success shadow-lg mb-0">
                        <h4>Upload Complete</h4>
                        <pre><asp:Label ID="lDone" CssClass="js-progressResults" runat="server" /></pre>
                        <asp:LinkButton ID="lViewImport" runat="server" AccessKey="s" ToolTip="Alt+s" Text="View Uploaded Schedules" CssClass="btn btn-default" OnClick="lbViewUpload_Click" />

                    </div>
                </asp:Panel>
                <div id="pnlUploadDetails" runat="server">
                    <div class="row d-flex justify-content-center">
                        <div class="col-lg-4 col-md-8">
                            <asp:Image ID="imgMyWellLogo" CssClass="margin-b-lg margin-t-md d-flex" Style="width: 50%; margin: auto" runat="server" />
                            <p style="color: #1a5f70">Welcome to the My Well Gateway tool for importing your schedules. Simply name your import, select your existing Financial Gateway, and upload the import CSV file we provided you.</p>
                            <Rock:RockTextBox ID="tbName" runat="server" Label="Import Name" Required="true" />
                            <Rock:FinancialGatewayPicker ID="fgMigratingFromFinancialGateway" runat="server" Label="Previous Financial Gateway" Help="This is the financial gateway you are migrating from. Gateway must be active in order to see it in the list." />
                            <Rock:FinancialGatewayPicker ID="fgMigratingToFinancialGateway" Required="true" runat="server" Label="My Well Financial Gateway" Help="This is the My Well financial gateway you are migrating to. Gateway must be active in order to see it in the list." />
                            <Rock:FileUploader ID="fuUploader" runat="server" DisplayMode="DropZone" IsBinaryFile="true" Required="true" Label="Import File" RequiredErrorMessage="A Document File is required." FormGroupCssClass="fileupload-group-lg" UploadButtonText="Drop File Here or Click to Select" Visible="true"></Rock:FileUploader>
                        </div>
                    </div>
                    <div class="actions">
                        <asp:LinkButton ID="lbImport" runat="server" AccessKey="s" ToolTip="Alt+s" Text="Upload Import File" CssClass="btn btn-primary" OnClick="lbImport_Click" />
                        <asp:LinkButton ID="lbCancel" runat="server" AccessKey="c" ToolTip="Alt+c" Text="Cancel" CssClass="btn btn-link" CausesValidation="false" OnClick="lbCancel_Click" />
                    </div>
                </div>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>

<style>
    @keyframes growProgressBarCircle {
        0%, 33% {
            --pgPercentage: 0;
        }

        100% {
            --pgPercentage: var(--value);
        }
    }

    @property --pgPercentage {
        syntax: '<number>';
        inherits: false;
        initial-value: 0;
    }

    div[role="progressbarcircle"] {
        --fg: #369;
        --bg: #def;
        --pgPercentage: var(--value);
        animation: growProgressBarCircle 3s 1 forwards;
        width: 100px;
        height: 100px;
        border-radius: 50%;
        display: grid;
        place-items: center;
        margin: auto;
        background: radial-gradient(closest-side, var(--color0) 80%, transparent 0 99.9%, var(--color1) 0), conic-gradient(var(--color2) calc(var(--pgPercentage) * 1%), var(--color3) 0);
        font-family: Helvetica, Arial, sans-serif;
        font-size: 20px;
        color: var(--color2);
        font-weight: 700;
    }

    .mywell-link-active {
        border-width: 0px 0px 3px;
        border-style: solid;
        border-color: transparent transparent rgb(0, 143, 204);
        color: rgb(0, 143, 204) !important;
    }

    .mywell-link {
        font-size: 20px;
        line-height: 32px;
        font-weight: 700;
        padding: 0px 8px 8px;
        text-decoration: none;
        color: rgba(52, 50, 50, 0.5);
    }

    .btn-outline-disbled {
        color: #000000;
        border-right-color: #c5c5c5;
        border-top-color: #c5c5c5;
        border-bottom-color: #c5c5c5;
        border-left-color: #c5c5c5;
    }
</style>
