System.register([ 'vue', '@Obsidian/Utility/guid', '@Obsidian/Core/Controls/financialGateway', '@Obsidian/Enums/Controls/gatewayEmitStrings', '@Obsidian/PageState' ], ( function ( exports )
{
    'use strict';
    var defineComponent, computed, ref, onMounted, nextTick, newGuid, onSubmitPayment, GatewayEmitStrings, useStore;
    return {
        setters: [ function ( module )
        {
            defineComponent = module.defineComponent;
            computed = module.computed;
            ref = module.ref;
            nextTick = module.nextTick;
            onMounted = module.onMounted;
        }, function ( module )
        {
            newGuid = module.newGuid;
        }, function ( module )
        {
            onSubmitPayment = module.onSubmitPayment;
        }, function ( module )
        {
            GatewayEmitStrings = module.GatewayEmitStrings;
        }, function (module) {
            useStore = module.useStore;
        } ],
        execute: ( function ()
        {
            var ministryBrandGatewayControl = exports( 'default', defineComponent( {
                name: "MinistryBrandGatewayControl",
                components: {
                },
                props: {
                    settings: {
                        type: Object,
                        required: true
                    }
                },
                setup ( props, _ref )
                {
                    var emit = _ref.emit;

                    var loading = ref( true );
                    var failedToLoad = ref( false );
                    var validationMessage = ref( "" );
                    var controlId = "ministrybrand_".concat( newGuid() );
                    var inputStyleHook = ref( null );
                    var inputInvalidStyleHook = ref( null );
                    var paymentInputs = ref(null);

                    var store = useStore();
                    var currentPerson = computed(() => {
                        return store.state.currentPerson;
                    });


                    var script = props.settings.gatewayBaseUrl + "/rock-connector.js";
                    nextTick(() => {
                        var scriptNode = document.createElement("script");
                        scriptNode.setAttribute("src", script);
                        document.head.appendChild(scriptNode);
                    });

                    onSubmitPayment( async () =>
                    {
                        if ( loading.value || failedToLoad.value )
                        {
                            return;
                        }

                        $('.actions > .btn-primary ').attr("disabled", true);

                        MBForm.submit( function (success, order) {
                            if (!success) {

                                let validationErrors = [];
                                if (order.error !== null || order.error !== undefined) {
                                    validationErrors = order.error.errors;
                                }

                                if (validationErrors.length > 0) {
                                    emit("validation", validationErrors );
                                } else {
                                    emit("error", "Validation Error");
                                }

                                $('.actions > .btn-primary ').removeAttr("disabled");

                            } else {
                                $("form .payment-method-options + .alert-danger").html(""); // Clear out old error

                                function waitForDecline() {
                                    var errors = $("form .payment-method-options + .alert-danger");
                                    if (errors.length && errors[0].innerText) {
                                        $('.actions > .btn-primary ').removeAttr("disabled");
                                    } else {
                                        setTimeout(waitForDecline, 100);
                                    }
                                }
                                waitForDecline();

                                emit(GatewayEmitStrings.Success, JSON.stringify(order))
                            }
                        }); 

                        loading.value = false;
                    });

                    var loadPayment = async function ()
                    {
                        var parent = document.querySelector("[id*='paymentIframe']").parentElement.parentElement;
                        var amount = parent.getAttribute( "amount" );

                        let getPaymentUrl = '/api/com_ministrybrands/get-payment-url/tokenize/' + encodeURIComponent(amount) + '/' +
                            props.settings.financialGatewayGuid;

                        if ( currentPerson !== null && currentPerson.value !== null ) {
                            getPaymentUrl = getPaymentUrl + '?personKey=' + encodeURIComponent(currentPerson.value.idKey);
                            if (currentPerson.value.firstName !== null && currentPerson.value.firstName !== '') {
                                getPaymentUrl = getPaymentUrl + '&firstName=' + encodeURIComponent(currentPerson.value.firstName);
                            }
                            if (currentPerson.value.lastName !== null && currentPerson.value.lastName !== '') {
                                getPaymentUrl = getPaymentUrl + '&lastName=' + encodeURIComponent(currentPerson.value.lastName);
                            }
                            if (currentPerson.value.email !== null && currentPerson.value.email !== '') {
                                getPaymentUrl = getPaymentUrl + '&email=' + encodeURIComponent(currentPerson.value.email);
                            }
                        }

                        const response = await fetch(getPaymentUrl, {
                            method: "GET",
                            headers: { "Content-Type": "application/json" }
                        });

                        const paymentUrl = await response.json();

                        $( "#paymentIframe" ).attr( 'src', paymentUrl )

                        function waitForMBForm() {
                            if ( typeof MBForm !== 'undefined' ) {
                                MBForm.init();
                            } else {
                                setTimeout( waitForMBForm, 100 );
                            }
                        }
                        waitForMBForm();

                        loading.value = false;
                    }

                    onMounted( async () =>
                    {
                        var _props$settings$token;
                        await loadPayment();
                    } );

                    return {
                        controlId,
                        loading,
                        failedToLoad,
                        validationMessage,
                        inputStyleHook,
                        inputInvalidStyleHook,
                        paymentInputs
                    };
                },
                template: `
                <div id="ember-payment">
                    <div v-if="loading" class="text-center">
                        Loading
                    </div>

                    <div v-show="!loading && !failedToLoad" style="max-width: 600px; margin: 0px auto;">
                        <iframe id="paymentIframe" style="width:100%; height:525px;"></iframe>
                    </div>
                </div>`
            } ) );

        } )
    };
} ) );
