<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ChargeSchedules.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ChargeSchedules" %>
<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <script src="/SignalR/hubs"></script>
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
            <!-- Request user to upload the csv and fill out required fields -->
            <div class="panel-body">
                <!--Errors that happen during activation of schedules -->
                <asp:Panel ID="pnUploadCSVErrors" Visible="false" runat="server">
                    <div class="alert alert-danger shadow-lg">
                        <h3 class="mt-0">
                            <asp:Label ID="nbWarningMessageHeader" runat="server" Text="<i class='fa fa-exclamation-triangle mr-2 text-yello-500'></i>Upload Failed"></asp:Label>

                        </h3>
                        <p>
                            <asp:Label ID="nbWarningMessage" runat="server" />
                        </p>
                    </div>
                </asp:Panel>
                <div id="pnlUploadDetails" runat="server">
                    <div class="row d-flex justify-content-center">
                        <div class="col-lg-4 col-md-8">
                            <asp:Image ID="imgMyWellLogo" CssClass="margin-b-lg margin-t-md d-flex" Style="width: 50%; margin: auto" runat="server" />
                            <p style="color: #1a5f70">Welcome to the My Well tool for charging schedules that failed to run. Simply select your Financial Gateway and upload the CSV file of schedule id's you want to charge.</p>
                            <Rock:FinancialGatewayPicker ID="fgMigratingFromFinancialGateway" Required="true" runat="server" Label="Previous Financial Gateway" Help="This is the financial gateway you are charging the schedule with. Gateway must be active in order to see it in the list." />
                            <Rock:FileUploader ID="fuUploader" runat="server" DisplayMode="DropZone" IsBinaryFile="true" Required="true" Label="Import File" RequiredErrorMessage="A Document File is required." FormGroupCssClass="fileupload-group-lg" UploadButtonText="Drop File Here or Click to Select" Visible="true"></Rock:FileUploader>
                        </div>
                    </div>
                    <div class="actions">
                        <asp:LinkButton ID="lbImport" runat="server" AccessKey="s" ToolTip="Alt+s" Text="Import" CssClass="btn btn-primary" OnClick="lbImport_Click" />
                    </div>
                </div>
                <!-- Import complete message-->
                <asp:Panel ID="pnlDone" runat="server" CssClass="panel-body js-messageContainer mt-4" Style="display: none">
                    <div class="alert alert-success shadow-lg mb-0">
                        <asp:Literal ID="ltCompleteTitle" Text="<h4>Charging Schedules Complete</h4>" runat="server"></asp:Literal>
                        <pre><asp:Label ID="lDone" CssClass="js-progressResults" runat="server" /></pre>
                        <asp:Literal ID="lViewImport" runat="server"></asp:Literal>
                    </div>
                </asp:Panel>
                <!-- Progress Message-->
                <asp:Panel ID="pnlProgress" runat="server" CssClass="panel-body js-messageContainer mt-4" Visible="false">
                    <div class="alert alert-warning shadow-lg mb-0">
                        <asp:Literal ID="ltProgressTitle" Text="<h4>Charging Schedules...</h4>" runat="server"></asp:Literal>
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
            </div>
        </asp:Panel>
        <script>


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
