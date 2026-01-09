<%@ Control Language="C#" AutoEventWireup="true" CodeFile="FinanceImport.ascx.cs" Inherits="RockWeb.Plugins.com_9embers.Finance.FinanceImport" %>

<script src="/SignalR/hubs"></script>
<script type="text/javascript">
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

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>

        <asp:Panel ID="pnlView" runat="server" CssClass="panel panel-block">

            <div class="panel-heading">
                <h1 class="panel-title">Finance Import
                </h1>
            </div>
            <asp:Panel runat="server" ID="pnlForm" CssClass="panel-body">
                <Rock:NotificationBox runat="server" NotificationBoxType="Info" Title="Please format your CSV in the following way"
                    Text="<br>Person Id, Envelope Number, Account Id, Activity, Amount, Date" />
                <Rock:DefinedValuePicker runat="server" ID="dvpTransactionSource" Label="Transaction Source" />
                <Rock:DefinedValuePicker runat="server" ID="dvpTransactionType" Required="true" Label="Transaction Type" />
                <Rock:DefinedValuePicker runat="server" ID="dvpCurrencyType" Required="true" Label="Currency Type" />
                <Rock:FileUploader runat="server" ID="fpCSV" Required="true" Label="CSV File" />
                <Rock:BootstrapButton runat="server" ID="btnImport" Text="Import" CssClass="btn btn-primary" OnClick="btnImport_Click" />
            </asp:Panel>

            <asp:Panel ID="pnlProgress" runat="server" CssClass="panel-body js-messageContainer" Visible="false">
                <strong>Importing Financial Transactions</strong><br />
                <div class="alert alert-info">
                    <asp:Label ID="lProgressMessage" CssClass="js-progressMessage" runat="server" Text="Loading..." />
                </div>
            </asp:Panel>

            <asp:Panel ID="pnlError" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                <strong>An Error Has Occurred: </strong>
                <br />
                <div class="alert alert-error">
                    <pre><asp:Label ID="lError" CssClass="js-progressResults" runat="server" /></pre>
                </div>
            </asp:Panel>

            <asp:Panel ID="pnlDone" runat="server" CssClass="panel-body js-messageContainer" Style="display: none">
                <strong>Import Complete</strong><br />
                <div class="alert alert-error">
                    <pre><asp:Label ID="lDone" CssClass="js-progressResults" runat="server" /></pre>
                </div>
            </asp:Panel>

        </asp:Panel>

    </ContentTemplate>
</asp:UpdatePanel>
