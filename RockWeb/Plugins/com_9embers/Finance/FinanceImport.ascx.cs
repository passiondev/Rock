using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Web.UI;
using System.Linq;
using System.Data.Entity;
using System.Data.SqlClient;
using Microsoft.AspNet.SignalR;
using System.Threading.Tasks;
using Rock.Web;

namespace RockWeb.Plugins.com_9embers.Finance
{

    [DisplayName( "Finance Import" )]
    [Category( "9 Embers > Finance" )]
    [Description( "Block for importing financial data from a CSV." )]

    #region Block Attributes

    [CustomDropdownListField( "Match People By",
        Description = "Changes how people are matched.",
        Key = AttributeKey.MatchBy,
        ListSource = "personid^Person Id,envelopenumber^Envelope Number",
        DefaultValue = "personaliasid",
        Order = 0,
        IsRequired = true
        )]

    [AttributeField( "Finance Activity Attribute",
        Description = "Financal Transaction Attribute for Activity information",
        Key = AttributeKey.FinancialActivityAttr,
        EntityTypeGuid = Rock.SystemGuid.EntityType.FINANCIAL_TRANSACTION,
        Order = 0,
        IsRequired = false
        )]

    #endregion Block Attributes
    public partial class FinanceImport : Rock.Web.UI.RockBlock
    {

        #region Attribute Keys

        private static class AttributeKey
        {
            internal const string FinancialActivityAttr = "FinancialActivityAttr";
            internal const string MatchBy = "MatchBy";
        }

        #endregion Attribute Keys

        #region PageParameterKeys

        private static class PageParameterKey
        {

        }

        #endregion PageParameterKeys

        #region Fields

        /// <summary>
        /// This holds the reference to the RockMessageHub SignalR Hub context.
        /// </summary>
        private IHubContext _hubContext = GlobalHost.ConnectionManager.GetHubContext<RockMessageHub>();

        /// <summary>
        /// Gets the signal r notification key.
        /// </summary>
        /// <value>
        /// The signal r notification key.
        /// </value>
        public string SignalRNotificationKey
        {
            get
            {
                return string.Format( "BulkRegistrationRefund_BlockId:{0}_SessionId:{1}", this.BlockId, Session.SessionID );
            }
        }

        #endregion Fields

        #region Properties

        // used for public / protected properties

        #endregion

        #region Base Control Methods

        //  overrides of the base RockBlock methods (i.e. OnInit, OnLoad)

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit( EventArgs e )
        {
            base.OnInit( e );

            // this event gets fired after block settings are updated. it's nice to repaint the screen if these settings would alter it
            this.BlockUpdated += Block_BlockUpdated;
            this.AddConfigurationUpdateTrigger( upnlContent );

            RockPage.AddScriptLink( "~/Scripts/jquery.signalR-2.2.0.min.js", fingerprint: false );
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad( EventArgs e )
        {
            base.OnLoad( e );


            if ( !Page.IsPostBack )
            {
                BindDropDowns();
            }
        }



        #endregion

        #region Events

        // handlers called by the controls on your block

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated( object sender, EventArgs e )
        {

        }

        protected void btnImport_Click( object sender, EventArgs e )
        {
            pnlForm.Visible = false;
            pnlProgress.Visible = true;

            var import = new Task( () => { ImportData(); } );
            import.Start();
        }



        #endregion

        #region Methods
        private void BindDropDowns()
        {
            dvpTransactionSource.DefinedTypeId = DefinedTypeCache.GetId( Rock.SystemGuid.DefinedType.FINANCIAL_SOURCE_TYPE.AsGuid() );
            dvpTransactionType.DefinedTypeId = DefinedTypeCache.GetId( Rock.SystemGuid.DefinedType.FINANCIAL_TRANSACTION_TYPE.AsGuid() );
            dvpCurrencyType.DefinedTypeId = DefinedTypeCache.GetId( Rock.SystemGuid.DefinedType.FINANCIAL_CURRENCY_TYPE.AsGuid() );
        }

        private void ImportData()
        {
            System.Threading.Thread.Sleep( 1000 ); //Dirty hack to make the other thread go first

            var currencyTypeValueId = dvpCurrencyType.SelectedDefinedValueId;
            if ( currencyTypeValueId == null )
            {
                currencyTypeValueId = DefinedValueCache.Get( Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_UNKNOWN ).Id;
            }

            WriteProgressMessage( "Parsing CSV" );
            List<string> errorMessages;
            List<FinancialItem> importData = GetImportData( fpCSV.BinaryFileId, false, out errorMessages );

            if ( errorMessages.Any() )
            {
                LogException( new Exception( "Error Parsing CSV. See inner exception for details", new Exception( string.Join( ";", errorMessages ) ) ) );
                WriteProgressMessage( "Could not parse CSV" );
                WriteErrorMessage( string.Join( "<br>", errorMessages ) );
                return;
            }

            WriteProgressMessage( "Finished Parsing CSV" );

            string activityAttributeKey;
            Dictionary<string, string> attributeLookup = GenerateDefinedValueLookup( GetAttributeValue( AttributeKey.FinancialActivityAttr ), out activityAttributeKey );


            //Create a new batch for all the transactions
            RockContext rockContext = new RockContext();
            FinancialBatchService financialBatchService = new FinancialBatchService( rockContext );

            FinancialBatch batch;

            try
            {
                batch = new FinancialBatch
                {
                    Name = "Imported Financial Data",
                    Note = "Batch created from financial import block.",
                    BatchStartDateTime = importData.OrderBy( i => i.DateTime ).FirstOrDefault().DateTime ?? Rock.RockDateTime.Today,
                    BatchEndDateTime = importData.OrderByDescending( i => i.DateTime ).FirstOrDefault().DateTime ?? Rock.RockDateTime.Today,
                    ControlAmount = importData.Select( i => i.Amount ).Sum()
                };
                financialBatchService.Add( batch );
                rockContext.SaveChanges();
            }
            catch ( Exception ex )
            {
                WriteProgressMessage( "Could not create batch" );
                WriteErrorMessage( ex.Message );
                LogException( ex );
                return;
            }

            var itemId = 1;
            var successful = 0;
            WriteProgressMessage( string.Format( "Importing item {0} of {1}", itemId, importData.Count ) );

            foreach ( var item in importData )
            {
                try
                {
                    if ( itemId % 10 == 0 )
                    {
                        WriteProgressMessage( string.Format( "Importing item {0} of {1}", itemId, importData.Count ) );
                    }

                    itemId++;

                    //Fresh Context for maximum speed
                    rockContext = new RockContext();
                    rockContext.WrapTransaction( () =>
                    {
                        FinancialTransactionService financialTransactionService = new FinancialTransactionService( rockContext );

                        var transaction = new FinancialTransaction
                        {
                            AuthorizedPersonAliasId = GetPersonAliasIdForItem( item ),
                            TransactionTypeValueId = dvpTransactionType.SelectedDefinedValueId ?? 0,
                            SourceTypeValueId = dvpTransactionSource.SelectedDefinedValueId,
                            TransactionDateTime = item.DateTime
                        };
                        transaction.BatchId = batch.Id;
                        financialTransactionService.Add( transaction );

                        var details = new FinancialTransactionDetail
                        {
                            AccountId = item.AccountId,
                            Amount = item.Amount
                        };
                        transaction.TransactionDetails.Add( details );

                        var paymentDetail = new FinancialPaymentDetail
                        {
                            CurrencyTypeValueId = currencyTypeValueId
                        };
                        transaction.FinancialPaymentDetail = paymentDetail;

                        rockContext.SaveChanges();

                        if ( activityAttributeKey.IsNotNullOrWhiteSpace() )
                        {
                            var activityValue = item.ActivityValue.ToLower();
                            if ( attributeLookup.ContainsKey( activityValue ) )
                            {
                                transaction.LoadAttributes( rockContext );
                                transaction.SetAttributeValue( activityAttributeKey, attributeLookup[activityValue] );
                                transaction.SaveAttributeValues( rockContext );
                            }
                        }
                    } );
                    successful++;
                }
                catch ( Exception ex )
                {
                    WriteErrorMessage( ex.Message );
                    LogException( ex );
                }
            }
            var pageRef = new PageReference( Rock.SystemGuid.Page.FINANCIAL_BATCH_DETAIL );

            _hubContext.Clients.All.done( this.SignalRNotificationKey,
                string.Format( "Successfully imported {0} of {1} records.<br><a href='/page/{2}?BatchId={3}'>Go to Batch</a>", successful, importData.Count, pageRef.PageId, batch.Id ) );
        }

        private int? GetPersonAliasIdForItem( FinancialItem item )
        {
            var searchType = GetAttributeValue( AttributeKey.MatchBy );

            if ( searchType == "envelopenumber" ) //Lookup by envelope number attribute 
            {
                var envelopeAttribute = AttributeCache.Get( Rock.SystemGuid.Attribute.PERSON_GIVING_ENVELOPE_NUMBER.AsGuid() );

                if ( envelopeAttribute == null )
                {
                    return null;
                }

                RockContext rockContext = new RockContext();
                AttributeValueService attributeValueService = new AttributeValueService( rockContext );
                PersonService personService = new PersonService( rockContext );

                var envelopes = attributeValueService.Queryable()
                    .AsNoTracking()
                    .Where( av => av.AttributeId == envelopeAttribute.Id && av.Value == item.EnvelopeNumber )
                    .ToList();

                if ( envelopes.Any() )
                {
                    var person = personService.GetNoTracking( envelopes.FirstOrDefault().EntityId ?? 0 );
                    if ( person == null )
                    {
                        return null;
                    }
                    if ( envelopes.Count == 1 )
                    {
                        return person.PrimaryAliasId;
                    }
                    else
                    {
                        var param = new SqlParameter()
                        {
                            ParameterName = "givingId",
                            Value = person.GivingId
                        };

                        var headOfHouseId = rockContext.Database.SqlQuery<int>( "SELECT[dbo].[ufnCrm_GetHeadOfHousePersonIdFromGivingId](@givingId)", param );

                        var headOfHouseHold = personService.GetNoTracking( headOfHouseId.FirstOrDefault() );
                        if ( headOfHouseHold != null )
                        {
                            return headOfHouseHold.PrimaryAliasId;
                        }
                        return person.PrimaryAliasId;
                    }
                }
            }
            else //Lookup by person id
            {
                RockContext rockContext = new RockContext();
                PersonService personService = new PersonService( rockContext );

                var person = personService.Queryable( true, true )
                    .AsNoTracking()
                    .Where( p => p.Id == item.PersonId )
                    .FirstOrDefault();

                if ( person != null )
                {
                    return person.PrimaryAliasId;
                }
            }
            return null;
        }

        private Dictionary<string, string> GenerateDefinedValueLookup( string attributeGuid, out string attributeKey )
        {
            attributeKey = "";
            var lookup = new Dictionary<string, string>();

            var attribute = AttributeCache.Get( attributeGuid.AsGuid() );
            var definedValueFieldTypeId = FieldTypeCache.GetId( Rock.SystemGuid.FieldType.DEFINED_VALUE.AsGuid() );

            if ( attribute == null || attribute.FieldTypeId != definedValueFieldTypeId )
            {
                return lookup;
            }

            if ( !attribute.QualifierValues.ContainsKey( "definedtype" ) )
            {
                return lookup;
            }

            var definedTypeId = attribute.QualifierValues["definedtype"].Value.AsIntegerOrNull();
            if ( !definedTypeId.HasValue )
            {
                return lookup;
            }

            var definedType = DefinedTypeCache.Get( definedTypeId.Value );
            if ( definedType == null )
            {
                return lookup;
            }

            lookup = definedType.DefinedValues.ToDictionary( v => v.Value.ToLower(), v => v.Guid.ToString() );
            attributeKey = attribute.Key;

            return lookup;

        }

        private List<FinancialItem> GetImportData( int? binaryFileId, bool skipFirstRow, out List<string> errorMessages )
        {
            errorMessages = new List<string>();

            RockContext rockContext = new RockContext();
            BinaryFileService binaryFileService = new BinaryFileService( rockContext );

            var csvBin = binaryFileService.Get( binaryFileId ?? 0 );

            var data = csvBin.ContentStream.ReadBytesToEnd();
            var csv = System.Text.Encoding.Default.GetString( data );

            csv = csv.Replace( "\r\n", "\n" );
            var rows = csv.Split( '\n' );

            var importData = new List<FinancialItem>();
            var rowId = 1;

            foreach ( var row in rows )
            {
                if ( row.IsNullOrWhiteSpace() )
                {
                    continue;
                }

                try
                {
                    var columns = row.Split( ',' );
                    var financialImport = new FinancialItem
                    {
                        PersonId = columns[0].AsIntegerOrNull(),
                        EnvelopeNumber = columns[1],
                        AccountId = columns[2].AsInteger(),
                        ActivityValue = columns[3],
                        Amount = columns[4].AsDecimal(),
                        DateTime = columns[5].AsDateTime()
                    };
                    importData.Add( financialImport );
                }
                catch
                {
                    errorMessages.Add( string.Format( "Could not import row {0}", rowId ) );
                }
                rowId++;
            }

            return importData;
        }

        private void WriteProgressMessage( string status )
        {
            _hubContext.Clients.All.receiveNotification( this.SignalRNotificationKey, status );
        }

        private void WriteErrorMessage( string errorText )
        {
            _hubContext.Clients.All.error( this.SignalRNotificationKey, errorText );
        }


        #endregion
    }

    class FinancialItem
    {
        public int? PersonId { get; set; }
        public string EnvelopeNumber { get; set; }
        public int AccountId { get; set; }
        public string ActivityValue { get; set; }
        public decimal Amount { get; set; }
        public DateTime? DateTime { get; set; }
    }
}