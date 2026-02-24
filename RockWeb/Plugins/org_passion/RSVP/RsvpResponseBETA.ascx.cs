// <copyright>
// Copyright by the Spark Development Network
//
// Licensed under the Rock Community License (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.rockrms.com/license
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// </copyright>

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data.Entity;
using System.Linq;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using Rock.Web.UI;
using Rock.Web.UI.Controls;
using Rock.Security;
using Newtonsoft.Json;
using Rock.Communication;
using Rock.Cms.StructuredContent;

namespace RockWeb.Blocks.RSVP
{
    /// <summary>
    /// Displays the details of the given RSVP occurrence.
    /// </summary>
    [DisplayName( "Passion RSVP BETA" )]
    [Category( "RSVP" )]
    [Description( "This is the test block!" )]

    #region Block Attributes

    [BooleanField( "Display Form When Signed In",
        Key = AttributeKey.DisplayFormWhenSignedIn,
        Description = "If signed in and Display Form When Signed In is disabled, only the accept and decline buttons are shown.",
        DefaultBooleanValue = true,
        Order = 0 )]

    [TextField( "Accept Button Label",
        Key = AttributeKey.AcceptButtonLabel,
        Description = "The label for the Accept button.",
        DefaultValue = "Accept",
        Order = 2 )]

    [TextField( "Decline Button Label",
        Key = AttributeKey.DeclineButtonLabel,
        Description = "The label for the Decline button.",
        DefaultValue = "Decline",
        Order = 3 )]

    [MemoField( "Default Accept Message",
        Key = AttributeKey.DefaultAcceptMessage,
        Description = "The default message displayed when an RSVP is accepted.",
        DefaultValue = "We have received your response. Thanks, and we’ll see you soon!",
        Order = 4,
        AllowHtml = true)]

    [MemoField( "Default Decline Message",
        Key = AttributeKey.DefaultDeclineMessage,
        Description = "The default message displayed when an RSVP is declined.",
        DefaultValue = "Sorry to hear you won’t make it, but hopefully we’ll see you again soon!",
        Order = 5 )]

    [DefinedValueField( "Default Decline Reasons",
        Key = AttributeKey.DefaultDeclineReasons,
        Description = "Default Decline Reasons to be displayed.  Setting decline reasons on the Attendance Occurrence will override these.",
        DefaultValue = "",
        Order = 6 )]

    [TextField( "Multigroup Mode RSVP Title",
        Key = AttributeKey.MultigroupModeRSVPTitle,
        Description = "The page title when a user is RSVPing for multiple groups.",
        DefaultValue = "",
        IsRequired =false,
        Order = 8 )]

    [MemoField( "Multigroup Accept Message",
        Key = AttributeKey.MultigroupAcceptMessage,
        Description = "The message displayed when one or more RSVPs are accepted in Multigroup mode.  Will include a list of accepted events with the key \"AcceptedRsvps\".",
        DefaultValue = "Thanks for letting us know!",
        Order = 9,
        AllowHtml = true)]

    [DefinedValueField(
        "Connection Status",
        Key = AttributeKey.ConnectionStatus,
        Description = "The connection status to use for new individuals (default = 'Web Prospect'.)",
        DefinedTypeGuid = "2E6540EA-63F0-40FE-BE50-F2A84735E600",
        IsRequired = true,
        AllowMultiple = false,
        DefaultValue = "368DD475-242C-49C4-A42C-7278BE690CC2",
        Order = 11)]

    [DefinedValueField(
        "Record Status",
        Key = AttributeKey.RecordStatus,
        Description = "The record status to use for new individuals (default = 'Pending'.)",
        DefinedTypeGuid = "8522BADD-2871-45A5-81DD-C76DA07E2E7E",
        IsRequired = true,
        AllowMultiple = false,
        DefaultValue = "283999EC-7346-42E3-B807-BCE9B2BABB49",
        Order = 12)]


    #endregion

    public partial class RSVPResponse : RockBlock
    {
        private static class AttributeKey
        {
            public const string DisplayFormWhenSignedIn = "DisplayFormWhenSignedIn";
            public const string AcceptButtonLabel = "AcceptButtonLabel";
            public const string DeclineButtonLabel = "DeclineButtonLabel";
            public const string DefaultAcceptMessage = "DefaultAcceptMessage";
            public const string DefaultDeclineMessage = "DefaultDeclineMessage";
            public const string DefaultDeclineReasons = "DefaultDeclineReasons";
            public const string MultigroupModeRSVPTitle = "MultigroupModeRSVPTitle";
            public const string MultigroupAcceptMessage = "MultigroupAcceptMessage";
            public const string ConnectionStatus = "ConnectionStatus";
            public const string RecordStatus = "RecordStatus";
        }

        private static class PageParameterKey
        {
            public const string AttendanceOccurrenceId = "AttendanceOccurrenceId";
            public const string AttendanceOccurrenceIds = "AttendanceOccurrenceIds";
            public const string PersonActionIdentifier = "p";
            public const string IsAccept = "IsAccept";
            public const string AcceptButtonText = "AcceptButtonText";
            public const string AcceptButtonColor = "AcceptButtonColor";
            public const string AcceptButtonFontColor = "AcceptButtonFontColor";
            public const string DeclineButtonText = "DeclineButtonText";
            public const string DeclineButtonColor = "DeclineButtonColor";
            public const string DeclineButtonFontColor = "DeclineButtonFontColor";
            public const string IncludeDecline = "IncludeDecline";
            
        }

        #region Properties

        /// <summary>
        /// Stores data collection for multiple occurrence responses.
        /// </summary>
        private List<OccurrenceDataItem> MultipleOccurrenceDataItems { get; set; }

        #endregion

        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit( EventArgs e )
        {
            base.OnInit( e );

            string script = @"
$('input.rsvp-list-input').each(function () {
    var $cbx = $(this)[0];

    if ($cbx.checked) {
        var $header = $(this).closest('header');
        $header.siblings('.panel-body').show();
    }
});

$('input.rsvp-list-input').on('click', function (e) {
    var $cbx = $(this)[0];
    var $header = $(this).closest('header');

    if ($cbx.checked) {
        $header.siblings('.panel-body').slideDown();
        $header.siblings('.panel-body').find('span[id$=rfv]').each(function () {
            document.getElementById($(this).attr('id')).enabled = true;
        });
    } else {
        $header.siblings('.panel-body').slideUp();
        $header.siblings('.panel-body').find('span[id$=rfv]').each(function () {
            document.getElementById($(this).attr('id')).enabled = false;
        });
    }
});

$(document).ready(function () {

    $('.js-rsvp-item').find('span[id$=rfv]').each(function () {
        document.getElementById($(this).attr('id')).enabled = false;
    });

});

";
            ScriptManager.RegisterStartupScript( this.Page, this.Page.GetType(), "DefinedValueChecklistScript", script, true );

            lbAccept_Multiple.Text = GetAttributeValue( AttributeKey.AcceptButtonLabel );
            lbAccept_Single.Text = GetAttributeValue( AttributeKey.AcceptButtonLabel );
            lbDecline_Single.Text = GetAttributeValue( AttributeKey.DeclineButtonLabel );

            

            SetButtonProperties();

            var person = GetPerson();
            if ( person == null )
            {
                // Invalid person action identifier and/or user is not logged in.
                nbNotAuthorized.Visible = true;
                return;
            }

            if ( !Page.IsPostBack )
            {
                bool isAccept = ( PageParameter( PageParameterKey.IsAccept ) == "1" );
                bool isDecline = ( PageParameter( PageParameterKey.IsAccept ) == "0" );
                var attendanceOccurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsIntegerOrNull();
                var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();

                

                if ( ( attendanceOccurrenceId == null ) && ( attendanceOccurrenceIdList.Count == 1 ) )
                {
                    // If only one occurrence ID is specified in the list, move it to the individual occurrence ID and treat it as a single RSVP response.
                    attendanceOccurrenceId = attendanceOccurrenceIdList.First();
                }

                if ( attendanceOccurrenceId != null )
                {
                    // Using a single occurrece.
                    if ( isAccept )
                    {
                        if ( GroupHasAttributes() )
                        {
                            ShowSingleOccurrence_Choice( attendanceOccurrenceId.Value, person );
                        }
                        else
                        {
                            WriteEmailAcceptResponse(attendanceOccurrenceId.Value, person);
                            ShowSingleOccurrence_Accept( attendanceOccurrenceId.Value, person );
                            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
                        }
                    }
                    else if ( isDecline )
                    {
                        ShowSingleOccurrence_Decline( attendanceOccurrenceId.Value, person );
                        ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
                    }
                    else
                    {
                        ShowSingleOccurrence_Choice( attendanceOccurrenceId.Value, person );
                    }               
                }
                else
                {
                    if ( attendanceOccurrenceIdList.Any() )
                    {
                        ShowMultipleOccurrence_Choice( attendanceOccurrenceIdList, person );
                    }
                    else
                    {
                        // No occurrence IDs were supplied.
                        Show404();
                    }
                }

            }
            else
            {
                var attendanceOccurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsIntegerOrNull();
                if ( attendanceOccurrenceId != null )
                {
                    BuildAttributeControls();
                }
                var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();
                if ( attendanceOccurrenceIdList.Any() )
                {
                    RebuildMultipleOccurrenceDataItems( attendanceOccurrenceIdList, person );
                }
            }
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad( EventArgs e )
        {
        }

        /// <summary>
        /// Saves any user control view-state changes that have occurred since the last page postback.
        /// </summary>
        /// <returns>
        /// Returns the user control's current view state. If there is no view state associated with the control, it returns null.
        /// </returns>
        protected override object SaveViewState()
        {
            var jsonSetting = new JsonSerializerSettings
            {
                ReferenceLoopHandling = ReferenceLoopHandling.Ignore,
                ContractResolver = new Rock.Utility.IgnoreUrlEncodedKeyContractResolver()
            };
            ViewState["MultipleOccurrenceDataItems"] = JsonConvert.SerializeObject( MultipleOccurrenceDataItems, Formatting.None, jsonSetting );
            return base.SaveViewState();
        }

        #endregion

        #region Events

        protected void lbAccept_Single_Click( object sender, EventArgs e )
        {
            valGuests.Visible = false;
            valGuests.Text = string.Empty;
            valDecline.Visible = false;
            valDecline.Text = string.Empty;

            var person = GetPerson();
            var attendanceOccurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsIntegerOrNull();
            if ( person == null || attendanceOccurrenceId == null )
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }

            //if ( string.IsNullOrWhiteSpace( PageParameter( PageParameterKey.PersonActionIdentifier ) ) )
            //{
            //    UpdatePersonRecord(person);
            //}
            
            if (dpBirthDate1.Visible && dpBirthDate1.Required && !dpBirthDate1.SelectedDate.HasValue && !string.IsNullOrEmpty(dpBirthDate1.Text))
            {
                valGuests.Text = "Please enter a valid birth date in MM/DD/YYYY format.";
                valGuests.Visible = true;
                return;
            }

            if (acAddress.Visible && acAddress.Required)
            {
                if (string.IsNullOrWhiteSpace(acAddress.Street1) || string.IsNullOrWhiteSpace(acAddress.City) ||
                    string.IsNullOrWhiteSpace(acAddress.State) || string.IsNullOrWhiteSpace(acAddress.PostalCode))
                {
                    valDecline.Text = "Please enter a complete address including street, city, state, and zip code.";
                    valDecline.Visible = true;
                    return;
                }
            }
            
            ShowSingleOccurrence_Accept( attendanceOccurrenceId.Value, person );
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbDecline_Single_Click( object sender, EventArgs e )
        {
            valGuests.Visible = false;
            valGuests.Text = string.Empty;
            valDecline.Visible = false;
            valDecline.Text = string.Empty;

            var person = GetPerson();
            var attendanceOccurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsIntegerOrNull();

            if ( rtbFirstName.Text.IsNullOrWhiteSpace() || rtbLastName.Text.IsNullOrWhiteSpace() || rebEmail.Text.IsNullOrWhiteSpace() )
            {
                // User did not fulfill Name & Email fields
                valDecline.Text = "You must provide your name/email before declining.";
                valDecline.Visible = true;
                return;
            }
            else if (dpBirthDate1.Visible && dpBirthDate1.Required && !dpBirthDate1.SelectedDate.HasValue && !string.IsNullOrEmpty(dpBirthDate1.Text))
            {
                valDecline.Text = "Please enter a valid birth date in MM/DD/YYYY format.";
                valDecline.Visible = true;
                return;
            }
            else if (acAddress.Visible && acAddress.Required)
            {
                if (string.IsNullOrWhiteSpace(acAddress.Street1) || string.IsNullOrWhiteSpace(acAddress.City) ||
                    string.IsNullOrWhiteSpace(acAddress.State) || string.IsNullOrWhiteSpace(acAddress.PostalCode))
                {
                    valDecline.Text = "Please enter a complete address including street, city, state, and zip code.";
                    valDecline.Visible = true;
                    return;
                }
            }
            else if (attendanceOccurrenceId == null)
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }



            ShowSingleOccurrence_Decline( attendanceOccurrenceId.Value, person );
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbAccept_Multiple_Click( object sender, EventArgs e )
        {
            var person = GetPerson();
            var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();
            if ( person == null || !attendanceOccurrenceIdList.Any() )
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }

            ShowMultipleOccurrence_Accept( attendanceOccurrenceIdList, person );
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbSaveDeclineReason_Click( object sender, EventArgs e )
        {
            int? declineReason = rrblDeclineReasons.SelectedValueAsInt();
            if ( declineReason.HasValue )
            {
                int occurrenceId = hfDeclineReason_OccurrenceId.Value.AsInteger();
                using ( var rockContext = new RockContext() )
                {
                    var person = GetPerson();
                    var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                    var occurrence = attendanceOccurrenceService.Get( occurrenceId );
                    person = new PersonService( rockContext ).Get( person.Guid );
                    UpdateOrCreateAttendanceRecord( occurrence, person, rockContext, Rock.Model.RSVP.No, null, declineReason.Value, rtbDeclineNote.Text );
                }
                pnlDeclineReasons.Visible = false;
                pnlDeclineReasonConfirmation.Visible = true;
                ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
            }
        }
        #endregion

        #region Internal Methods

        /// <summary>
        /// Writes the email accept response when it's necessary to show the choice form.
        /// </summary>
        /// <param name="occurrenceId"></param>
        /// <param name="person"></param>
        private void WriteEmailAcceptResponse( int occurrenceId, Person person )
        {
            using ( var rockContext = new RockContext() )
            {
                var occurrence = new AttendanceOccurrenceService( rockContext ).Get( occurrenceId );
                person = new PersonService( rockContext ).Get( person.Guid );
                UpdateOrCreateAttendanceRecord( occurrence, person, rockContext, Rock.Model.RSVP.Yes );
            }
        }

        /// <summary>
        /// Gets the list of Occurrence IDs from the query string.
        /// </summary>
        private List<int> GetMultipleOccurrenceIds()
        {
            var attendanceOccurrenceIdList = new List<int>();
            string attendanceOccurrenceIds = PageParameter( PageParameterKey.AttendanceOccurrenceIds );
            if ( !string.IsNullOrWhiteSpace( attendanceOccurrenceIds ) )
            {
                try
                {
                    attendanceOccurrenceIdList = attendanceOccurrenceIds.Split( ',' ).Select( int.Parse ).ToList();
                }
                catch
                {
                    /* Ignore failures to convert query string to integer values. */
                }
            }
            return attendanceOccurrenceIdList;
        }

        /// <summary>
        /// Returns a Person record for a PersonActionIdentifier for the action type "RSVP", or the currently logged in person if no PersonActionIdentifier is present.
        /// </summary>
        /// <returns></returns>
        private Person GetPerson()
        {
            string personActionIdentifier = PageParameter( PageParameterKey.PersonActionIdentifier );
            if ( !string.IsNullOrWhiteSpace( personActionIdentifier ) )
            {
                // Get Person record from PersonActionIdentifier.
                using ( var rockContext = new RockContext() )
                {
                    var personService = new PersonService( rockContext );
                    return personService.GetByPersonActionIdentifier( personActionIdentifier, "RSVP" );
                }
            }
            else
            {
                if (!Page.IsPostBack)
                {
                    return new Person();
                }
                else
                {
                    return CreatePerson();
                }
            }

        }

        /// <summary>
        /// Creates the person.
        /// </summary>
        /// <returns></returns>
        private Person CreatePerson()
        {
            var rockContext = new RockContext();

            var personService = new PersonService(rockContext);
            var personQuery = new PersonService.PersonMatchQuery(rtbFirstName.Text.Trim(), rtbLastName.Text.Trim(), rebEmail.Text.Trim(), string.Empty);
            var matchPerson = personService.FindPerson(personQuery, true);

            if(matchPerson != null)
            {
                return matchPerson;
            }
            else
            {
                DefinedValueCache dvcConnectionStatus = DefinedValueCache.Get(GetAttributeValue(AttributeKey.ConnectionStatus).AsGuid());
                DefinedValueCache dvcRecordStatus = DefinedValueCache.Get(GetAttributeValue(AttributeKey.RecordStatus).AsGuid());

                Person person = new Person();
                person.FirstName = rtbFirstName.Text;
                person.LastName = rtbLastName.Text;
                person.Email = rebEmail.Text;
                person.IsEmailActive = true;
                person.EmailPreference = EmailPreference.EmailAllowed;
                // WE WOULD NEED TO COPY THIS SECTION FOR ADDRESS + MARITAL + GENDER TO SAVE THOSE PROPERTIES TO THE PERSON WHO WAS JUST MATCHED OR CREATED

                /*
                if (!string.IsNullOrWhiteSpace(PhoneNumber.CleanNumber(pnbPhone.Number)))
                {
                    int phoneNumberTypeId = 12;

                        var phoneNumber = person.PhoneNumbers.FirstOrDefault(n => n.NumberTypeValueId == phoneNumberTypeId);
                        string oldPhoneNumber = string.Empty;
                        if (phoneNumber == null)
                        {
                            phoneNumber = new PhoneNumber { NumberTypeValueId = phoneNumberTypeId };
                            person.PhoneNumbers.Add(phoneNumber);
                        }
                        else
                        {
                            oldPhoneNumber = phoneNumber.NumberFormattedWithCountryCode;
                        }

                        phoneNumber.CountryCode = PhoneNumber.CleanNumber(pnbPhone.CountryCode);
                        phoneNumber.Number = PhoneNumber.CleanNumber(pnbPhone.Number);

                }
                
                
                if (dvpMaritalStatus1.SelectedDefinedValueId != ' ')
                    {
                person.MaritalStatusValueId = dvpMaritalStatus1.SelectedDefinedValueId.ToIntSafe();
                }

                if(rblGender.SelectedValueAsEnumOrNull<Gender>() != null)
                {
                    person.Gender = rblGender.SelectedValueAsEnum<Gender>();
                }

                if(dpBirthDate1 != null)
                {
                person.SetBirthDate(dpBirthDate1.SelectedDate);
                }
                


                
                var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                if (homeLocationType != null)
                {
                    // Find a location record for the address that was entered
                    var loc = new Location();
                    acAddress.GetValues(loc);
                    if (acAddress.Street1.IsNotNullOrWhiteSpace() && loc.City.IsNotNullOrWhiteSpace())
                    {
                        loc = new LocationService( rockContext ).Get(
                            loc.Street1, loc.Street2, loc.City, loc.State, loc.PostalCode, loc.Country, true);
                    }
                    else
                    {
                        loc = null;
                    }

                    // Check to see if family has an existing home address
                    var primaryFamily = person.PrimaryFamily;
                    var groupLocation = primaryFamily.GroupLocations
                        .FirstOrDefault(l =>
                           l.GroupLocationTypeValueId.HasValue &&
                           l.GroupLocationTypeValueId.Value == homeLocationType.Id);

                    if (loc != null)
                    {
                        if (groupLocation == null || groupLocation.LocationId != loc.Id)
                        {
                            // If family does not currently have a home address or it is different than the one entered, add a new address (move old address to prev)
                            GroupService.AddNewGroupAddress(rockContext, primaryFamily, homeLocationType.Guid.ToString(), loc, true, string.Empty, true, true);
                        }
                    }
                    else
                    {
                        if (groupLocation != null)
                        {
                            // If an address was not entered, and family has one on record, update it to be a previous address
                            var prevLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_PREVIOUS.AsGuid());
                            if (prevLocationType != null)
                            {
                                groupLocation.GroupLocationTypeValueId = prevLocationType.Id;
                            }
                        }
                    }
                }
                */

                person.RecordTypeValueId = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.PERSON_RECORD_TYPE_PERSON.AsGuid()).Id;
                if (dvcConnectionStatus != null)
                {
                    person.ConnectionStatusValueId = dvcConnectionStatus.Id;
                }

                if (dvcRecordStatus != null)
                {
                    person.RecordStatusValueId = dvcRecordStatus.Id;
                }

                PersonService.SaveNewPerson(person, rockContext, null, false);

                return person;

            }

            
        }

        /// <summary>
        /// Display a "not found" message for actions which cannot be performed.
        /// </summary>
        /// <param name="PageTitle">The optional page title to display.</param>
        private void Show404( bool isExpired = false, string PageTitle = "" )
        {
            //Context.Response.StatusCode = 404;
            pnl404.Visible = true;
            pnlForm.Visible = false;
            pnlMultiple_Accept.Visible = false;
            pnlMultiple_Choice.Visible = false;
            pnlSingle_Accept.Visible = false;
            pnlSingle_Choice.Visible = false;
            pnlSingle_Decline.Visible = false;

            if ( isExpired )
            {
                if ( string.IsNullOrWhiteSpace( PageTitle ) )
                {
                    pnlHeading.Visible = false;
                }
                else
                {
                    lHeading.Text = PageTitle;
                }

                nbExpired.Visible = true;
            }
            else
            {
                pnlHeading.Visible = false;
                nbNotFound.Visible = true;
            }
        }

        /// <summary>
        /// Calculates the display title for an <see cref="AttendanceOccurrence"/>.
        /// </summary>
        /// <param name="occurrence">The <see cref="AttendanceOccurrence"/>.</param>
        private string GetOccurrenceTitle( AttendanceOccurrence occurrence )
        {
            bool hasTitle = ( !string.IsNullOrWhiteSpace( occurrence.Name ) );
            bool hasSchedule = ( occurrence.Schedule != null );

            if ( hasSchedule )
            {
                // This block is unnecessary if the event has a name (because the name will take priority over the schedule, anyway), but it
                // has been intentionally left in place to prevent anyone from creating an unintentional bug in the future, as it affects
                // the logic below.
                Ical.Net.CalendarComponents.CalendarEvent calendarEvent = occurrence.Schedule.GetICalEvent();
                if ( calendarEvent == null )
                {
                    hasSchedule = false;
                }
            }

            if ( hasTitle )
            {
                return occurrence.Name;
            }
            else if ( hasSchedule )
            {
                return string.Format(
                    "{0} - {1}, {2}",
                    occurrence.Group.Name,
                    occurrence.OccurrenceDate.ToString( "dddd, MMMM d, yyyy" ),
                    occurrence.Schedule.GetICalEvent().DtStart.AsSystemLocal.TimeOfDay.ToTimeString());
            }
            else
            {
                return string.Format(
                    "{0} - {1}",
                    occurrence.Group.Name,
                    occurrence.OccurrenceDate.ToString( "dddd, MMMM d, yyyy" ) );
            }
        }

        /// <summary>
        /// Shows the Accept/Decline options to allow RSVP for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowSingleOccurrence_Choice(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);
                var group = occurrence.Group;
                group.LoadAttributes();
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                // groupMember.LoadAttributes();
                occurrence.LoadAttributes();
                var activeMembers = group.ActiveMembers().Count();
                var attendees = occurrence.Attendees;
                var members = group.ActiveMembers();
                var allowGuest = group.GetAttributeValue("Info_AllowForGuests")?.AsBoolean();
                var acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                var occClosedDate = occurrence.GetAttributeValue("ClosedDate")?.AsDateTime();
                int totalGuests = 0;
                // Calculate number of guests from attendees and set remaining capacity
                if (allowGuest == true)
                {
                    foreach (var a in attendees)
                    {
                        foreach (GroupMember gm in members)
                        {
                            gm.LoadAttributes();
                            int gc = gm.GetAttributeValue("GuestCount1").ToIntSafe();
                            if (gm.Person.Aliases.Contains(a.PersonAlias))
                            {
                                totalGuests += gc;
                                if (gm.PersonId == person.Id)
                                {
                                    totalGuests -= gc;
                                }
                            }
                        }
                    }
                    // Set the new acceptedRSVPs variable based on confirmed guests
                    acceptedRSVPs += totalGuests;
                }
                int? remainingCapacity = group.GroupCapacity - acceptedRSVPs;

                if (occClosedDate == null)
                {
                    occClosedDate = occurrence.OccurrenceDate.EndOfDay();
                }

                if (occurrence == null)
                {
                    Show404();
                    return;
                }
                else if (occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity )
                {
                    // This event has expired.
                    Show404(true, GetOccurrenceTitle(occurrence));
                    return;
                }

                // lHeading.Text = $"{acceptedRSVPs} // {remainingCapacity}";
                lHeading.Text = GetOccurrenceTitle(occurrence);
                pnlSingle_Choice.Visible = true;


                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }

                bool displayForm = GetAttributeValue(AttributeKey.DisplayFormWhenSignedIn).AsBoolean();
                pnlForm.Visible = (CurrentPersonId == null || displayForm);

                if (!string.IsNullOrWhiteSpace(PageParameter(PageParameterKey.PersonActionIdentifier)))
                {
                    rtbFirstName.Enabled = false;
                    rtbLastName.Enabled = false;
                    rebEmail.Enabled = false;
                }

                rtbFirstName.Text = person.FirstName;
                rtbLastName.Text = person.LastName;
                rebEmail.Text = person.Email;




                // This collection object is created to limit attribute values to those marked "IsPublic".
                var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);

                if (publicAttributes.Attributes.Any())
                {
                    Helper.AddEditControls(publicAttributes, phAttributes, true);
                }

                // This collection object is created to find which person fields are enabled through group attributes marked as boolean 'true'


                var pncheck = group.GetAttributeValue("Info_PhoneNumber");
                var adrcheck = group.GetAttributeValue("Info_Address");
                var gndcheck = group.GetAttributeValue("Info_Gender");
                var mscheck = group.GetAttributeValue("Info_MaritalStatus");
                var bdcheck = group.GetAttributeValue("Info_BirthDate");
                //var allowGuest = group.GetAttributeValue("AllowForGuests");


                if (pncheck == "True")
                {
                    pnbPhone.Visible = true;
                    pnbPhone.Required = true;
                    try
                    {
                        pnbPhone.Number = new PhoneNumberService(new RockContext()).GetNumberByPersonIdAndType(person.Id, "407E7E45-7B2E-4FCD-9605-ECB1339F2453").NumberFormatted;
                    }
                    catch
                    {

                    }
                }
                
                if (adrcheck == "True")
                {
                    acAddress.Visible = true;
                    acAddress.Required = true;
                    Group family = null;
                    Person adult1 = null;
                    Person adult2 = null;

                    // If there is a logged in person, attempt to find their family and spouse.
                    if (person != null)
                    {
                        Person spouse = null;

                        // Get all their families
                        var families = person.GetFamilies(rockContext);
                        if (families.Any())
                        {
                            // Get their spouse
                            spouse = person.GetSpouse(rockContext);
                            if (spouse != null)
                            {
                                // If spouse was found, find the first family that spouse belongs to also.
                                family = families.Where(f => f.Members.Any(m => m.PersonId == spouse.Id)).FirstOrDefault();
                                if (family == null)
                                {
                                    // If there was not family with spouse, something went wrong and assume there is no spouse.
                                    spouse = null;
                                }
                            }

                            // If we didn't find a family yet (by checking spouses family), assume the first family.
                            if (family == null)
                            {
                                family = families.FirstOrDefault();
                            }

                            // Assume Adult1 is the current person
                            adult1 = person;
                            if (spouse != null)
                            {
                                // and Adult2 is the spouse
                                adult2 = spouse;

                                // However, if spouse is actually head of family, make them Adult1 and current person Adult2
                                var headOfFamilyId = family.Members
                                    .OrderBy(m => m.GroupRole.Order)
                                    .ThenBy(m => m.Person.Gender)
                                    .Select(m => m.PersonId)
                                    .FirstOrDefault();
                                if (headOfFamilyId != 0 && headOfFamilyId == spouse.Id)
                                {
                                    adult1 = spouse;
                                    adult2 = person;
                                }
                            }
                        }

                        if (family != null)
                        {

                            // Set the address from the family
                            var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                            if (homeLocationType != null)
                            {
                                var location = family.GroupLocations
                                    .Where(l =>
                                       l.GroupLocationTypeValueId.HasValue &&
                                       l.GroupLocationTypeValueId.Value == homeLocationType.Id)
                                    .Select(l => l.Location)
                                    .FirstOrDefault();
                                acAddress.SetValues(location);
                            }
                            else
                            {
                                acAddress.SetValues(null);
                            }
                        }
                    }
                }
                
                    if (gndcheck == "True")
                    {
                        rblGender.Visible = true;
                        rblGender.Required = true;
                        rblGender.SetValue(person != null ? person.Gender.ConvertToInt() : 0);


                    }

                    if (mscheck == "True")
                    {
                        dvpMaritalStatus1.Visible = true;
                        dvpMaritalStatus1.Required = true;
                        try
                        {
                            dvpMaritalStatus1.SelectedDefinedValueId = person.MaritalStatusValueId;
                        }
                        catch
                        {

                        }
                    }

                    if (bdcheck == "True")
                    {
                        dpBirthDate1.Visible = true;
                        dpBirthDate1.Required = true;
                        try
                        {
                            if (person.BirthDate.HasValue)
                            {
                                dpBirthDate1.SelectedDate = person.BirthDate;
                            }
                        }
                        catch
                        {

                        }
                    }

                    if (allowGuest == true)
                    {
                        divGuestCount.Visible = true;
                    }
            }
        }
        /// <summary>
        /// Rebuilds the dynamic attribute value controls (for single occurrence mode) after a postback.
        /// </summary>
        private void BuildAttributeControls()
        {
            using ( var rockContext = new RockContext() )
            {
                var person = GetPerson();
                var occurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsInteger();
                var occurrence = new AttendanceOccurrenceService( rockContext ).Get( occurrenceId );
                var groupMember = occurrence.Group.Members.Where( gm => gm.PersonId == person.Id ).FirstOrDefault();
                if ( groupMember == null )
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }
                var publicAttributes = new GroupMemberPublicAttriuteCollection( groupMember );
                if ( publicAttributes.Attributes.Any() )
                {
                    Helper.AddEditControls( publicAttributes, phAttributes, false );
                }
            }
        }

        /// <summary>
        /// Tests the group to see if there are any GroupMember attributes.
        /// </summary>
        /// <returns></returns>
        private bool GroupHasAttributes()
        {
            using ( var rockContext = new RockContext() )
            {
                var person = GetPerson();
                var occurrenceId = PageParameter( PageParameterKey.AttendanceOccurrenceId ).AsInteger();
                var occurrence = new AttendanceOccurrenceService( rockContext ).Get( occurrenceId );
                var groupMember = occurrence.Group.Members.Where( gm => gm.PersonId == person.Id ).FirstOrDefault();
                if ( groupMember == null )
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }

                groupMember.LoadAttributes();
                var publicAttributes = new GroupMemberPublicAttriuteCollection( groupMember );
                return publicAttributes.Attributes.Any();
            }
        }

        /// <summary>
        /// Shows the RSVP Accept message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>
        
        private void ShowSingleOccurrence_Accept( int occurrenceId, Person person )
        {
            using ( var rockContext = new RockContext() )
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                var occurrence = attendanceOccurrenceService.Get( occurrenceId );
                var group = occurrence.Group;
                group.LoadAttributes();
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                // Set Closed Date based on occurrence info 
                occurrence.LoadAttributes();
                var occClosedDate = occurrence.GetAttributeValue("ClosedDate")?.AsDateTime();
                if (occClosedDate == null)
                {
                    occClosedDate = occurrence.OccurrenceDate.EndOfDay();
                }

                // Load members and attendees
                var members = group.ActiveMembers();
                var activeMembers = group.ActiveMembers().Count();
                var attendees = occurrence.Attendees;
                
                var allowGuest = group.GetAttributeValue("Info_AllowForGuests")?.AsBoolean();
                int acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                int totalGuests = 0;
                int guestCount = rnbGuestCount.IntegerValue.ToIntSafe() + 1; //Add one to include the person who submits

                // Calculate number of guests from attendees and set remaining capacity
                if (allowGuest == true)
                {
                    foreach (var a in attendees)
                    {
                        foreach (GroupMember gm in members)
                        {
                            gm.LoadAttributes();
                            int gc = gm.GetAttributeValue("GuestCount1").ToIntSafe();
                            if (gm.Person.Aliases.Contains(a.PersonAlias))
                            {
                                totalGuests += gc;
                                // If person already exists, don't count their guest count attribute
                                if (gm.PersonId == person.Id)
                                {
                                    totalGuests -= gc;
                                    acceptedRSVPs -= 1;
                                }
                            }
                        }
                    }

                    acceptedRSVPs += totalGuests;
                }
                int? remainingCapacity = group.GroupCapacity - acceptedRSVPs;
                
                // Display result based on capacity or date
                if (occurrence == null)
                {
                    Show404();
                    return;
                }
                else if (occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity )
                {
                    // This event has expired or run out of capacity
                    Show404(true, GetOccurrenceTitle(occurrence));
                    return;
                }
                else if (guestCount > remainingCapacity)
                {
                    // There isn't enough space for you and your guests
                    valGuests.Text = $"This event has room for {remainingCapacity} more people.";
                    valGuests.Visible = true;
                    return;
                }
                
                valGuests.Visible = false;
                valDecline.Visible = false;

                lHeading.Text = GetOccurrenceTitle(occurrence);

                person = new PersonService( rockContext ).Get( person.Guid );
                UpdateOrCreateAttendanceRecord( occurrence, person, rockContext, Rock.Model.RSVP.Yes, phAttributes );
                
                var attendance = occurrence.Attendees.Where(a => person.Aliases.Contains(a.PersonAlias)).FirstOrDefault();

                // Show Single Occurrence Accept message.
                pnlSingle_Accept.Visible = true;
                pnlSingle_Choice.Visible = false;
                pnlForm.Visible = false;

                var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields( RockPage, person );
                mergeFields.Add("OccurrenceName", occurrence.Name);
                mergeFields.Add("Person", person);
                mergeFields.Add("OccurrenceDate", occurrence.OccurrenceDate.ToShortDateString());
                mergeFields.Add("OccurrenceTime", attendance.StartDateTime.ToShortTimeString());
                if (allowGuest == true)
                {
                mergeFields.Add("GuestCount", rnbGuestCount.IntegerValue);
                }

                //// Send Confirmation Message from Group Type (not ideal... have to revise)
                
                occurrence.Group.LoadAttributes(rockContext);
                if (occurrence.Group.GroupTypeId == 176)
                {
                    var sendemail = group.GetAttributeValue("Comm_SendConfirmation")?.AsBoolean() ?? false;
                    var email_content = group.GetAttributeValue("Comm_ConfirmationEmail") ?? null;
                    if (email_content != null)
                    {
                        email_content = email_content.Replace("/GetImage.ashx?", "https://connect.passion.team/GetImage.ashx?");
                        email_content = new StructuredContentHelper(email_content).Render();
                        email_content = email_content.Replace("<img ", "<img style='width: 100%;'");
                    } 
                    if (sendemail == true && email_content != null)
                    {
                        // Pull Email Fields from Group
                        var fromName = group.GetAttributeValue("Comm_FromName");
                        var fromEmail = group.GetAttributeValue("Comm_FromEmail");
                        var replyToEmail = group.GetAttributeValue("Comm_ReplyToEmail");
                        var emailSubject = group.GetAttributeValue("Comm_EmailSubject");

                        var message = new RockEmailMessage();
                        message.AddRecipient(new RockEmailMessageRecipient(person, mergeFields));
                        message.Message = email_content;
                        message.AdditionalMergeFields = mergeFields;
                        message.FromName = (fromName.IsNullOrWhiteSpace() == true) ? fromName : "Passion City Church";
                        message.FromEmail = (fromEmail.IsNullOrWhiteSpace() == true) ? fromEmail : "connect@passioncitychurch.com";
                        message.ReplyToEmail = (replyToEmail.IsNullOrWhiteSpace() == true) ? replyToEmail : "connect@passioncitychurch.com";
                        message.Subject = (emailSubject.IsNullOrWhiteSpace() == true) ? emailSubject : "RSVP Confirmed: " + group.Name;

                        message.AppRoot = ResolveRockUrl("~/");
                        message.ThemeRoot = ResolveRockUrl("~~/");
                        message.CreateCommunicationRecord = true;
                        message.Send();
                        rockContext.SaveChanges();
                    }
                }
                else
                {
                    var templateGuid = group.GetAttributeValue("EmailTemplate");
                    var template = new CommunicationTemplateService(rockContext).Get(templateGuid.AsGuid());

                    if (!string.IsNullOrEmpty(templateGuid))
                    {
                        var message = new RockEmailMessage();
                        message.AddRecipient(new RockEmailMessageRecipient(person, mergeFields));
                        message.Message = template.Message;
                        message.AdditionalMergeFields = mergeFields;
                        message.FromEmail = template.FromEmail;
                        if (string.IsNullOrEmpty(message.FromEmail))
                        {
                            message.FromEmail = "connect@passioncitychurch.com";
                        }
                        message.FromName = template.FromName;
                        if (string.IsNullOrEmpty(message.FromName))
                        {
                            message.FromName = "Passion City Church";
                        }
                        message.Subject = template.Subject;
                        if (string.IsNullOrEmpty(message.Subject))
                        {
                            message.Subject = occurrence.Name;
                        }
                        message.AppRoot = ResolveRockUrl("~/");
                        message.ThemeRoot = ResolveRockUrl("~~/");
                        message.CreateCommunicationRecord = true;
                        message.Send();
                        rockContext.SaveChanges();
                    }
                }

                if (!string.IsNullOrEmpty(occurrence.AcceptConfirmationMessage))
                {
                    nbAccept.Text = occurrence.AcceptConfirmationMessage.ResolveMergeFields(mergeFields);
                }
                else
                {
                    nbAccept.Text = GetAttributeValue(AttributeKey.DefaultAcceptMessage).ResolveMergeFields(mergeFields);
                }

                Authorization.SignOut();
            }
        }

        /// <summary>
        /// Creates a new attendance record or updates an existing one if it already exists.
        /// </summary>
        /// <param name="occurrence">The AttendanceOccurrence record.</param>
        /// <param name="person">The Person record.</param>
        /// <param name="rockContext">The RockContext</param>
        /// <param name="rsvpStatus">The Rock.Model.RSVP enum value to set.</param>
        /// <param name="attributePlaceHolder">(Optional) PlaceHolder control that contains the GroupMember attribute values to set.</param>
        /// <param name="declineReasonId">(Optional) The DefinedValue ID of a Decline Reason, if one was selected.  Only used if rsvpStatus is No.</param>
        /// <param name="declineNote">(Optional) An explanation of the reason for declining.  Only used if rsvpStatus is No.</param>
        private void UpdateOrCreateAttendanceRecord( AttendanceOccurrence occurrence, Person person, RockContext rockContext, Rock.Model.RSVP rsvpStatus, PlaceHolder attributePlaceHolder = null, int declineReasonId = 0, string declineNote = "" )
        {
            var attendance = occurrence.Attendees.Where(a => person.Aliases.Contains(a.PersonAlias)).FirstOrDefault();
            if (attendance == null)
            {
                attendance = new Attendance();
                attendance.OccurrenceId = occurrence.Id;
                attendance.PersonAliasId = person.PrimaryAliasId;
                attendance.DidAttend = false;
                attendance.StartDateTime = occurrence.Schedule != null && occurrence.Schedule.HasSchedule() ? occurrence.OccurrenceDate.Date.Add(occurrence.Schedule.StartTimeOfDay) : occurrence.OccurrenceDate;
                occurrence.Attendees.Add(attendance);
            }
            attendance.RSVP = rsvpStatus;
            attendance.RSVPDateTime = DateTime.Now;
            if (rsvpStatus == Rock.Model.RSVP.No)
            {
                if (declineReasonId != 0)
                {
                    attendance.DeclineReasonValueId = declineReasonId;
                }
                attendance.Note = declineNote;

                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;

                    new GroupMemberService(rockContext).Add(groupMember);
                    rockContext.SaveChanges();
                }
                groupMember.GroupMemberStatus = GroupMemberStatus.Inactive;
                
            }

            // Note that GroupMember attributes are being set, here.  If this control saves multiple attendance records for a same group (e.g., the same group meets on multiple dates and the user RSVPs to
            // more than one) it will overwrite values.
            if ((attributePlaceHolder != null) && (rsvpStatus == Rock.Model.RSVP.Yes))
            {
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;

                    new GroupMemberService(rockContext).Add(groupMember);
                    rockContext.SaveChanges();
                }
                groupMember.GroupMemberStatus = GroupMemberStatus.Active;

                

                groupMember.LoadAttributes();

                if (rnbGuestCount.IntegerValue > 0)
                {
                    groupMember.SetAttributeValue("GuestCount1", rnbGuestCount.IntegerValue);
                }

                Helper.GetEditValues(attributePlaceHolder, groupMember);

                groupMember.SaveAttributeValues();
            }

            UpdatePersonRecord(person);
            rockContext.SaveChanges();
        }

        /// <summary>
        /// Shows the RSVP Decline message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowSingleOccurrence_Decline( int occurrenceId, Person person )
        {
            using ( var rockContext = new RockContext() )
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                var occurrence = attendanceOccurrenceService.Get( occurrenceId );
                var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                lHeading.Text = GetOccurrenceTitle(occurrence);
                if ( occurrence == null )
                {
                    Show404();
                    return;
                }
                else if ( occClosedDate < RockDateTime.Now )
                {
                    // This event has expired.
                    Show404( true, GetOccurrenceTitle( occurrence ) );
                    return;
                }

                pnlForm.Visible = false;
                pnlSingle_Choice.Visible = false;
                valDecline.Visible = false;

                
                person = new PersonService(rockContext).Get(person.Guid);
                if ( person == null )
                {
                    return;
                }
                else
                {
                    UpdateOrCreateAttendanceRecord( occurrence, person, rockContext, Rock.Model.RSVP.No );
                }
                hfDeclineReason_OccurrenceId.Value = occurrenceId.ToString();

                // Show Single Occurrence Decline form.
                pnlSingle_Decline.Visible = true;
                

                var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields( RockPage, CurrentPerson );
                if ( !string.IsNullOrEmpty( occurrence.DeclineConfirmationMessage ) )
                {
                    nbDecline.Text = occurrence.DeclineConfirmationMessage.ResolveMergeFields( mergeFields );
                }
                else
                {
                    nbDecline.Text = GetAttributeValue( AttributeKey.DefaultDeclineMessage ).ResolveMergeFields( mergeFields );
                }

                if ( occurrence.ShowDeclineReasons == true )
                {
                    // Show Decline Reasons.
                    string declineReasons = occurrence.DeclineReasonValueIds;
                    if ( string.IsNullOrWhiteSpace( declineReasons ) )
                    {
                        // Use default decline reasons (block setting).
                        declineReasons = GetAttributeValue( AttributeKey.DefaultDeclineReasons );
                    }

                    var declineReasonValues = GetDeclineReasons( declineReasons );
                    if ( declineReasonValues.Any() )
                    {
                        rrblDeclineReasons.DataSource = declineReasonValues;
                        rrblDeclineReasons.DataBind();
                        pnlDeclineReasons.Visible = true;
                    }
                    else
                    {
                        pnlDeclineReasons.Visible = false;
                    }
                }
            }
        }

        protected class OccurrenceDataItem
        {
            public string Title { get; set; }
            public string OccurrenceId { get; set; }
            public GroupMemberPublicAttriuteCollection PublicAttributes { get; set; }
        };

        /// <summary>
        /// Shows the Accept/Decline options to allow RSVP for muiltiple occurrences.
        /// </summary>
        /// <param name="occurrenceIds">The List of IDs of the AttendanceOccurrences.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowMultipleOccurrence_Choice( List<int> occurrenceIds, Person person )
        {
            lHeading.Text = GetAttributeValue( AttributeKey.MultigroupModeRSVPTitle );

            bool displayForm = GetAttributeValue( AttributeKey.DisplayFormWhenSignedIn ).AsBoolean();
            pnlForm.Visible = ( CurrentPersonId == null || displayForm );

            if ( !string.IsNullOrWhiteSpace( PageParameter( PageParameterKey.PersonActionIdentifier ) ) )
            {
                rtbFirstName.Enabled = false;
                rtbLastName.Enabled = false;
                rebEmail.Enabled = false;
            }

            rtbFirstName.Text = person.FirstName;
            rtbLastName.Text = person.LastName;
            rebEmail.Text = person.Email;
            
            
            try
            {
                pnbPhone.Number = new PhoneNumberService(new RockContext()).GetNumberByPersonIdAndType(person.Id, "407E7E45-7B2E-4FCD-9605-ECB1339F2453").NumberFormatted;
            }
            catch
            {
                
            }
            
            bool hasValidOccurrences = false;
            bool isExpired = false;

            using ( var rockContext = new RockContext() )
            {
                List<OccurrenceDataItem> repeaterItems = new List<OccurrenceDataItem>();
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                foreach ( int occurrenceId in occurrenceIds )
                {
                    var occurrence = attendanceOccurrenceService.Get( occurrenceId );
                    var group = occurrence.Group;
                    var activeMembers = group.ActiveMembers().Count();
                    var acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                    var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                    if ( occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity)
                    {
                        // This event has expired.
                        isExpired = true;
                        continue;
                    }

                    // At least one occurrence is valid.
                    hasValidOccurrences = true;

                    var groupMember = occurrence.Group.Members.Where( gm => gm.PersonId == person.Id ).FirstOrDefault();
                    if ( groupMember == null )
                    {
                        //Person is not a member of the group associated with this invitation.
                        groupMember = new GroupMember();
                        groupMember.PersonId = person.Id;
                        groupMember.GroupId = occurrence.Group.Id;
                        groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                    }

                    groupMember.LoadAttributes();

                    // This collection object is created to limit attribute values to those marked "IsPublic".
                    var publicAttributes = new GroupMemberPublicAttriuteCollection( groupMember );

                    // Add item to collection for data binding.
                    repeaterItems.Add(
                        new OccurrenceDataItem()
                        {
                            Title = GetOccurrenceTitle( occurrence ),
                            OccurrenceId = occurrenceId.ToString(),
                            PublicAttributes = publicAttributes
                        } );
                }

                /// If no valid occurrences were found, display "Not Found" panel.
                if ( !hasValidOccurrences )
                {
                    Show404( isExpired, GetAttributeValue( AttributeKey.MultigroupModeRSVPTitle ) );
                }
                else
                {
                    pnlMultiple_Choice.Visible = true;
                    MultipleOccurrenceDataItems = repeaterItems;
                    BindMultipleOccurrenceRepeater();
                }
            }
        }

        private void RebuildMultipleOccurrenceDataItems( List<int> occurrenceIds, Person person )
        {
            using ( var rockContext = new RockContext() )
            {
                List<OccurrenceDataItem> repeaterItems = new List<OccurrenceDataItem>();
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                

                foreach ( int occurrenceId in occurrenceIds )
                {
                    var occurrence = attendanceOccurrenceService.Get( occurrenceId );
                    var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                    if ( occClosedDate < RockDateTime.Now )
                    {
                        continue;
                    }

                    var groupMember = occurrence.Group.Members.Where( gm => gm.PersonId == person.Id ).FirstOrDefault();
                    if ( groupMember == null )
                    {
                        //Person is not a member of the group associated with this invitation.
                        groupMember = new GroupMember();
                        groupMember.PersonId = person.Id;
                        groupMember.GroupId = occurrence.Group.Id;
                        groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                    }

                    groupMember.LoadAttributes();

                    // This collection object is created to limit attribute values to those marked "IsPublic".
                    var publicAttributes = new GroupMemberPublicAttriuteCollection( groupMember );

                    // Add item to collection for data binding.
                    repeaterItems.Add(
                        new OccurrenceDataItem()
                        {
                            Title = GetOccurrenceTitle( occurrence),
                            OccurrenceId = occurrenceId.ToString(),
                            PublicAttributes = publicAttributes
                        } );
                }

                MultipleOccurrenceDataItems = repeaterItems;
                BindMultipleOccurrenceRepeater();
            }
        }

        /// <summary>
        /// Binds the repeater control for multiple occurrences.
        /// </summary>
        private void BindMultipleOccurrenceRepeater()
        {
            rptrValues.DataSource = MultipleOccurrenceDataItems;
            rptrValues.DataBind();
        }

        /// <summary>
        /// Shows the RSVP Accept message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceIds">The List of IDs of the AttendanceOccurrences.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowMultipleOccurrence_Accept( List<int> occurrenceIds, Person person )
        {
            using ( var rockContext = new RockContext() )
            {
                _processedOccurrences = new List<string>();
                bool occurrenceProcessed = false;
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );

                foreach ( RepeaterItem item in rptrValues.Items )
                {
                    if ( ProcessOccurrence( person, item, rockContext ) )
                    {
                        occurrenceProcessed = true;
                    }
                }

                // If no occurrences were selected, do nothing.
                if ( occurrenceProcessed )
                {
                    // Show Multiple Occurrence Accept message.
                    pnlMultiple_Accept.Visible = true;
                    pnlMultiple_Choice.Visible = false;
                    pnlForm.Visible = false;

                    var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields( RockPage, CurrentPerson );
                    mergeFields.Add( "AcceptedRsvps", _processedOccurrences );
                    nbAcceptMultiple.Text = GetAttributeValue( AttributeKey.MultigroupAcceptMessage ).ResolveMergeFields( mergeFields );
                    nbNoOccurrencesSelected.Visible = false;
                }
                else
                {
                    nbNoOccurrencesSelected.Visible = true;
                }

                Authorization.SignOut();
            }
        }

        /// <summary>
        /// Stores a list of occurrences that were accepted, for inclusion in the Lava accept message.
        /// </summary>
        private List<string> _processedOccurrences;

        /// <summary>
        /// Processes a single RSVP Occurrence from data contained in a PanelWidget control.
        /// </summary>
        /// <param name="person">The Person record.</param>
        /// <param name="widget">The PanelWidget control.</param>
        /// <param name="rockContext">The RockContext.</param>
        /// <returns></returns>
        private bool ProcessOccurrence( Person person, RepeaterItem item, RockContext rockContext )
        {
            RockCheckBox rcbAccept = item.FindControl( "rcbAccept" ) as RockCheckBox;
            if ( rcbAccept.Checked )
            {
                HiddenField hfOccurrenceId = item.FindControl( "hfOccurrenceId" ) as HiddenField;
                PlaceHolder phOccurrenceAttributes = item.FindControl( "phOccurrenceAttributes" ) as PlaceHolder;

                int occurrenceId = int.Parse( hfOccurrenceId.Value );
                var attendanceOccurrenceService = new AttendanceOccurrenceService( rockContext );
                var occurrence = attendanceOccurrenceService.Get( occurrenceId );

                person = new PersonService( rockContext ).Get( person.Guid );
                UpdateOrCreateAttendanceRecord( occurrence, person, rockContext, Rock.Model.RSVP.Yes, phOccurrenceAttributes );
                _processedOccurrences.Add( GetOccurrenceTitle( occurrence ) );
            }
            return rcbAccept.Checked;

            Authorization.SignOut();
        }

        /// <summary>
        /// Updates the person record with name and email address fields.  This method is only called when NOT using a PersonActionIdentifier (i.e., the user must be logged in).
        /// </summary>
        private void UpdatePersonRecord(Person CurrentPerson)
        {
            using ( var rockContext = new RockContext() )
            {
                CurrentPerson.FirstName = rtbFirstName.Text;
                CurrentPerson.LastName = rtbLastName.Text;
                CurrentPerson.Email = rebEmail.Text;
                


                if (!string.IsNullOrWhiteSpace(PhoneNumber.CleanNumber(pnbPhone.Number)))
                {
                    int phoneNumberTypeId = 12;

                    var phoneNumber = CurrentPerson.PhoneNumbers.FirstOrDefault(n => n.NumberTypeValueId == phoneNumberTypeId);
                    string oldPhoneNumber = string.Empty;
                    if (phoneNumber == null)
                    {
                        phoneNumber = new PhoneNumber { NumberTypeValueId = phoneNumberTypeId };
                        CurrentPerson.PhoneNumbers.Add(phoneNumber);
                    }
                    else
                    {
                        oldPhoneNumber = phoneNumber.NumberFormattedWithCountryCode;
                    }

                    phoneNumber.CountryCode = PhoneNumber.CleanNumber(pnbPhone.CountryCode);
                    phoneNumber.Number = PhoneNumber.CleanNumber(pnbPhone.Number);

                }
                if (!string.IsNullOrWhiteSpace(rblGender.SelectedValue))
                {
                    CurrentPerson.Gender = rblGender.SelectedValue.ConvertToEnum<Gender>();
                }
                if (!string.IsNullOrWhiteSpace(dvpMaritalStatus1.SelectedDefinedValueId.ToString()))
                {
                    CurrentPerson.MaritalStatusValueId = dvpMaritalStatus1.SelectedDefinedValueId;
                }

                if (dpBirthDate1.SelectedDate.HasValue)
                {
                    CurrentPerson.SetBirthDate(dpBirthDate1.SelectedDate);
                }

                if (!string.IsNullOrWhiteSpace(acAddress.Street1) && !string.IsNullOrWhiteSpace(acAddress.City))
                {
                    var groupService = new GroupService(rockContext);
                    var familyGuid = CurrentPerson.GetFamily().Guid;
                    var primaryFamily = groupService.Get(familyGuid);
                    bool saveEmptyValues = primaryFamily != null;
                    var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                    if (homeLocationType != null)
                    {
                        // Find a location record for the address that was entered
                        var loc = new Location();
                        acAddress.GetValues(loc);
                        if (acAddress.Street1.IsNotNullOrWhiteSpace() && loc.City.IsNotNullOrWhiteSpace())
                        {
                            loc = new LocationService(rockContext).Get(
                                loc.Street1, loc.Street2, loc.City, loc.State, loc.PostalCode, loc.Country, primaryFamily, true);
                        }
                        else
                        {
                            loc = null;
                        }

                        // Check to see if family has an existing home address
                        var groupLocation = primaryFamily.GroupLocations
                            .FirstOrDefault(l =>
                               l.GroupLocationTypeValueId.HasValue &&
                               l.GroupLocationTypeValueId.Value == homeLocationType.Id);

                        if (loc != null)
                        {
                            if (groupLocation == null || groupLocation.LocationId != loc.Id)
                            {
                                // If family does not currently have a home address or it is different than the one entered, add a new address (move old address to prev)
                                GroupService.AddNewGroupAddress(rockContext, primaryFamily, homeLocationType.Guid.ToString(), loc, true, string.Empty, true, true);
                            }
                        }
                        else
                        {
                            if (groupLocation != null && saveEmptyValues)
                            {
                                // If an address was not entered, and family has one on record, update it to be a previous address
                                var prevLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_PREVIOUS.AsGuid());
                                if (prevLocationType != null)
                                {
                                    groupLocation.GroupLocationTypeValueId = prevLocationType.Id;
                                }
                            }
                        }

                        //rockContext.SaveChanges();
                    }
                }
                rockContext.SaveChanges();
            }
        }

        /// <summary>
        /// Get Decline Reason DefinedValues for a list of IDs.
        /// </summary>
        /// <param name="commaDelimitedDeclineReasons">The IDs of the DevinedValues to retrieve.</param>
        /// <returns></returns>
        protected List<DefinedValue> GetDeclineReasons( string commaDelimitedDeclineReasons )
        {
            List<DefinedValue> values = new List<DefinedValue>();
            List<int> declineReasonIds = new List<int>();
            if ( !string.IsNullOrWhiteSpace( commaDelimitedDeclineReasons ) )
            {
                declineReasonIds = commaDelimitedDeclineReasons.Split( ',' ).Select( int.Parse ).ToList();
            }

            if ( !declineReasonIds.Any() )
            {
                return values;
            }

            using ( var rockContext = new RockContext() )
            {
                var def = new DefinedValueService( rockContext );
                values = def.Queryable()
                    .Where( v => declineReasonIds.Contains( v.Id ) )
                    .AsNoTracking().ToList();
            }

            return values;
        }

        /// <summary>
        /// Sets the button style and text properties to match query string values passed in by the email editor.
        /// </summary>
        private void SetButtonProperties()
        {
            string acceptButtonText = PageParameter( PageParameterKey.AcceptButtonText );
            string acceptButtonColor = PageParameter( PageParameterKey.AcceptButtonColor );
            string acceptButtonFontColor = PageParameter( PageParameterKey.AcceptButtonFontColor );
            string declineButtonText = PageParameter( PageParameterKey.DeclineButtonText );
            string declineButtonColor = PageParameter( PageParameterKey.DeclineButtonColor );
            string declineButtonFontColor = PageParameter( PageParameterKey.DeclineButtonFontColor );
            string includeDecline = PageParameter(PageParameterKey.IncludeDecline);
            

            if ( !string.IsNullOrWhiteSpace( acceptButtonText ) )
            {
                lbAccept_Multiple.Text = acceptButtonText;
                lbAccept_Single.Text = acceptButtonText;
            }

            if ( !string.IsNullOrWhiteSpace( declineButtonText ) )
            {
                lbDecline_Single.Text = declineButtonText;
            }

            string acceptButtonStyle = string.Empty;
            if ( !string.IsNullOrWhiteSpace( acceptButtonColor ) )
            {
                acceptButtonStyle = "background-color: " + acceptButtonColor ;
            }
            if ( !string.IsNullOrWhiteSpace( acceptButtonFontColor ) )
            {
                acceptButtonStyle = acceptButtonStyle + "color: " + acceptButtonFontColor + ";";
            }
            if ( !string.IsNullOrWhiteSpace( acceptButtonStyle ) )
            {
                lbAccept_Multiple.CssClass = "btn";
                lbAccept_Multiple.Attributes.Remove( "style" );
                lbAccept_Multiple.Attributes.Add( "style", acceptButtonStyle );
                lbAccept_Single.CssClass = "btn form-group";
                lbAccept_Single.Attributes.Remove( "style" );
                lbAccept_Single.Attributes.Add( "style", acceptButtonStyle );
            }
            else
            {
                lbAccept_Multiple.CssClass = "btn btn-primary";
                lbAccept_Single.CssClass = "btn btn-primary";
            }


            string declineButtonStyle = string.Empty;
            if ( !string.IsNullOrWhiteSpace( declineButtonColor ) )
            {
                declineButtonStyle = "background-color: " + declineButtonColor ;
            }
            if ( !string.IsNullOrWhiteSpace( declineButtonFontColor ) )
            {
                declineButtonStyle = declineButtonStyle + "color: " + declineButtonFontColor + ";";
            }
            if ( !string.IsNullOrWhiteSpace( declineButtonStyle ) )
            {
                lbDecline_Single.CssClass = "btn";
                lbDecline_Single.Attributes.Remove( "style" );
                lbDecline_Single.Attributes.Add( "style", declineButtonStyle );
            }
            else
            {
                lbDecline_Single.CssClass = "btn btn-default";
            }

            if (includeDecline == "false")
            {
                lbDecline_Single.Visible = false;
            }
        }

        #endregion

        protected void rptrValues_ItemDataBound( object sender, RepeaterItemEventArgs e )
        {
            var dataItem = e.Item.DataItem as OccurrenceDataItem;
            var phOccurrenceAttributes = e.Item.FindControl( "phOccurrenceAttributes" );
            if ( dataItem.PublicAttributes.Attributes.Any() )
            {
                Helper.AddEditControls( dataItem.PublicAttributes, phOccurrenceAttributes, !Page.IsPostBack );
            }
        }
    }

    #region Helper Classes

    /// <summary>
    /// This class is used to obtain a list of attributes which are marked IsPublic.
    /// </summary>
    public class GroupMemberPublicAttriuteCollection : IHasAttributes
    {
        
        /// <summary>
        /// Gets the id.
        /// </summary>
        public int Id { get; set; }

        /// <summary>
        /// List of attributes associated with the object.  This property will not include the attribute values.
        /// The <see cref="AttributeValues" /> property should be used to get attribute values.  Dictionary key
        /// is the attribute key, and value is the cached attribute
        /// </summary>
        /// <value>
        /// The attributes.
        /// </value>
        public Dictionary<string, AttributeCache> Attributes { get; set; }

        /// <summary>
        /// Dictionary of all attributes and their value.  Key is the attribute key, and value is the associated attribute value
        /// </summary>
        /// <value>
        /// The attribute values.
        /// </value>
        public Dictionary<string, AttributeValueCache> AttributeValues { get; set; }

        /// <summary>
        /// Gets the attribute value defaults.  This property can be used by a subclass to override the parent class's default
        /// value for an attribute
        /// </summary>
        /// <value>
        /// The attribute value defaults.
        /// </value>
        public Dictionary<string, string> AttributeValueDefaults
        {
            get { return null; }
        }

        /// <summary>
        /// Gets the value of an attribute key.
        /// </summary>
        /// <param name="key">The key.</param>
        /// <returns></returns>
        public string GetAttributeValue( string key )
        {
            if ( this.AttributeValues != null &&
                this.AttributeValues.ContainsKey( key ) )
            {
                return this.AttributeValues[key].Value;
            }

            if ( this.Attributes != null &&
                this.Attributes.ContainsKey( key ) )
            {
                return this.Attributes[key].DefaultValue;
            }

            return null;
        }

        /// <summary>
        /// Gets the value of an attribute key - splitting that delimited value into a list of strings.
        /// </summary>
        /// <param name="key">The key.</param>
        /// <returns>
        /// A list of string values or an empty list if none exist.
        /// </returns>
        public List<string> GetAttributeValues( string key )
        {
            string value = GetAttributeValue( key );
            if ( !string.IsNullOrWhiteSpace( value ) )
            {
                return value.SplitDelimitedValues().ToList();
            }

            return new List<string>();
        }

        /// <summary>
        /// Takes the broken URL from a structured content field and puts an absolute URL, which is a parameter
        /// </summary>
        /// <param url="URL">The key.</param>
        /// <returns>
        /// The structured content JSON payload with the updated URL field for images
        /// </returns>
        /* public string ReplaceUrl(string content, string url)
        {
            string new_content = content.Replace("/GetImage.ashx?", url);

            return new_content;
        }
        */
        /// <summary>
        /// Sets the value of an attribute key in memory.  Note, this will not persist value to database
        /// </summary>
        /// <param name="key">The key.</param>
        /// <param name="value">The value.</param>
        public void SetAttributeValue( string key, string value )
        {
            if ( this.AttributeValues != null &&
                this.AttributeValues.ContainsKey( key ) )
            {
                this.AttributeValues[key].Value = value;
            }
        }

        /// <summary>
        /// Initializes a new instance of the <see cref="GroupMemberPublicAttriuteCollection"/> class.
        /// </summary>
        public GroupMemberPublicAttriuteCollection( GroupMember groupMember )
        {
            Id = groupMember.Id;
            groupMember.LoadAttributes();
            Attributes = groupMember.Attributes.Where( a => a.Value.IsPublic == true ).ToDictionary( a => a.Key, a => a.Value );
            AttributeValues = groupMember.AttributeValues.Where( a => Attributes.Keys.Contains( a.Value.AttributeKey ) ).ToDictionary( a => a.Key, a => a.Value );
        }

        public GroupMemberPublicAttriuteCollection() { }
    }

    public static class DateEndOfDayStaticFunction
    {
        public static DateTime EndOfDay( this DateTime input )
        {
            return input.Date.AddDays( 1 ).AddMilliseconds( -1 );
        }
    }
    #endregion
}