System.register(['vue', '@Obsidian/Utility/block', '@Obsidian/Enums/Crm/gender', '@Obsidian/Templates/block', '@Obsidian/Controls/rockButton.obs', '@Obsidian/Controls/grid', '@Obsidian/Controls/loadingIndicator.obs', '@Obsidian/Controls/notificationBox.obs', '@Obsidian/Controls/modal.obs'], (function (exports) {
  'use strict';
  var pushScopeId, popScopeId, createTextVNode, createElementVNode, defineComponent, ref, openBlock, createBlock, unref, withCtx, toDisplayString, createCommentVNode, createElementBlock, createVNode, normalizeClass, Fragment, renderList, reactive, useConfigurationValues, useInvokeBlockAction, Gender, Block, RockButton, Grid, TextColumn, Column, LoadingIndicator, NotificationBox, Modal;
  return {
    setters: [function (module) {
      pushScopeId = module.pushScopeId;
      popScopeId = module.popScopeId;
      createTextVNode = module.createTextVNode;
      createElementVNode = module.createElementVNode;
      defineComponent = module.defineComponent;
      ref = module.ref;
      openBlock = module.openBlock;
      createBlock = module.createBlock;
      unref = module.unref;
      withCtx = module.withCtx;
      toDisplayString = module.toDisplayString;
      createCommentVNode = module.createCommentVNode;
      createElementBlock = module.createElementBlock;
      createVNode = module.createVNode;
      normalizeClass = module.normalizeClass;
      Fragment = module.Fragment;
      renderList = module.renderList;
      reactive = module.reactive;
    }, function (module) {
      useConfigurationValues = module.useConfigurationValues;
      useInvokeBlockAction = module.useInvokeBlockAction;
    }, function (module) {
      Gender = module.Gender;
    }, function (module) {
      Block = module["default"];
    }, function (module) {
      RockButton = module["default"];
    }, function (module) {
      Grid = module["default"];
      TextColumn = module.TextColumn;
      Column = module.Column;
    }, function (module) {
      LoadingIndicator = module["default"];
    }, function (module) {
      NotificationBox = module["default"];
    }, function (module) {
      Modal = module["default"];
    }],
    execute: (function () {

      function asyncGeneratorStep(gen, resolve, reject, _next, _throw, key, arg) {
        try {
          var info = gen[key](arg);
          var value = info.value;
        } catch (error) {
          reject(error);
          return;
        }
        if (info.done) {
          resolve(value);
        } else {
          Promise.resolve(value).then(_next, _throw);
        }
      }
      function _asyncToGenerator(fn) {
        return function () {
          var self = this,
            args = arguments;
          return new Promise(function (resolve, reject) {
            var gen = fn.apply(self, args);
            function _next(value) {
              asyncGeneratorStep(gen, resolve, reject, _next, _throw, "next", value);
            }
            function _throw(err) {
              asyncGeneratorStep(gen, resolve, reject, _next, _throw, "throw", err);
            }
            _next(undefined);
          });
        };
      }

      var _withScopeId = n => (pushScopeId("data-v-5389bf33"), n = n(), popScopeId(), n);
      var _hoisted_1 = {
        key: 1
      };
      var _hoisted_2 = {
        key: 0
      };
      var _hoisted_3 = {
        class: "mb-5"
      };
      var _hoisted_4 = _withScopeId(() => createElementVNode("i", {
        class: "fa fa-angle-left"
      }, null, -1));
      var _hoisted_5 = createTextVNode(" Go Back");
      var _hoisted_6 = {
        class: "row mb-5"
      };
      var _hoisted_7 = {
        class: "col-md-6 col-12"
      };
      var _hoisted_8 = {
        class: "m-0"
      };
      var _hoisted_9 = {
        class: "mt-3"
      };
      var _hoisted_10 = {
        class: "col-md-6 col-12"
      };
      var _hoisted_11 = {
        class: "shadow bg-light rounded p-3"
      };
      var _hoisted_12 = {
        class: "row"
      };
      var _hoisted_13 = {
        class: "col-sm-3 col-12"
      };
      var _hoisted_14 = _withScopeId(() => createElementVNode("small", {
        class: "font-weight-bold text-muted"
      }, "Gender", -1));
      var _hoisted_15 = {
        class: "mt-2 text-primary"
      };
      var _hoisted_16 = {
        class: "col-sm-3 col-12"
      };
      var _hoisted_17 = _withScopeId(() => createElementVNode("small", {
        class: "font-weight-bold text-muted"
      }, "Location", -1));
      var _hoisted_18 = {
        class: "mt-2 text-primary"
      };
      var _hoisted_19 = {
        class: "col-sm-3 col-12"
      };
      var _hoisted_20 = _withScopeId(() => createElementVNode("small", {
        class: "font-weight-bold text-muted"
      }, "Date", -1));
      var _hoisted_21 = {
        class: "mt-2 text-primary"
      };
      var _hoisted_22 = {
        class: "col-sm-3 col-12"
      };
      var _hoisted_23 = _withScopeId(() => createElementVNode("small", {
        class: "font-weight-bold text-muted"
      }, "Time", -1));
      var _hoisted_24 = {
        class: "mt-2 text-primary"
      };
      var _hoisted_25 = {
        class: "mb-4"
      };
      var _hoisted_26 = {
        class: "grid-obsidian grid-bordered grid-striped"
      };
      var _hoisted_27 = _withScopeId(() => createElementVNode("div", {
        class: "grid-heading"
      }, [createElementVNode("div", {
        class: "grid-column-heading"
      }, [createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Name")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Gender")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Location")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 20%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Day")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Time")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 5%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Projects")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 5%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Match Percentage")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "0 0 110px"
        }
      })])], -1));
      var _hoisted_28 = {
        class: "grid-body"
      };
      var _hoisted_29 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var _hoisted_30 = {
        class: "grid-row grid-row-odd"
      };
      var _hoisted_31 = _withScopeId(() => createElementVNode("div", {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      }, null, -1));
      var _hoisted_32 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_33 = {
        class: "match-item match"
      };
      var _hoisted_34 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_35 = {
        class: "match-item match"
      };
      var _hoisted_36 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 20%"
        }
      };
      var _hoisted_37 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_38 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_39 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_40 = ["innerHTML"];
      var _hoisted_41 = ["innerHTML"];
      var _hoisted_42 = ["innerHTML"];
      var _hoisted_43 = _withScopeId(() => createElementVNode("div", {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 5%"
        }
      }, null, -1));
      var _hoisted_44 = _withScopeId(() => createElementVNode("div", {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 5%"
        }
      }, null, -1));
      var _hoisted_45 = _withScopeId(() => createElementVNode("div", {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "0 0 110px"
        }
      }, null, -1));
      var _hoisted_46 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var _hoisted_47 = {
        key: 0,
        class: "mb-4"
      };
      var _hoisted_48 = _withScopeId(() => createElementVNode("h6", null, "SELECTED PERSON", -1));
      var _hoisted_49 = {
        class: "grid-obsidian grid-bordered grid-striped"
      };
      var _hoisted_50 = {
        class: "grid-body"
      };
      var _hoisted_51 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var _hoisted_52 = {
        class: "grid-row grid-row-odd"
      };
      var _hoisted_53 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_54 = ["title"];
      var _hoisted_55 = {
        key: 0,
        class: "fa fa-exclamation-circle mr-2"
      };
      var _hoisted_56 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_57 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_58 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 20%"
        }
      };
      var _hoisted_59 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_60 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_61 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_62 = ["innerHTML"];
      var _hoisted_63 = ["innerHTML"];
      var _hoisted_64 = ["innerHTML"];
      var _hoisted_65 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 5%"
        }
      };
      var _hoisted_66 = ["role"];
      var _hoisted_67 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 5%"
        }
      };
      var _hoisted_68 = _withScopeId(() => createElementVNode("div", {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "0 0 110px"
        }
      }, null, -1));
      var _hoisted_69 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var _hoisted_70 = ["title"];
      var _hoisted_71 = {
        key: 0,
        class: "fa fa-exclamation-circle mr-2"
      };
      var _hoisted_72 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_73 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_74 = ["innerHTML"];
      var _hoisted_75 = ["innerHTML"];
      var _hoisted_76 = ["innerHTML"];
      var _hoisted_77 = ["role", "onClick"];
      var _hoisted_78 = {
        class: "d-flex justify-content-between align-items-center"
      };
      var _hoisted_79 = createTextVNode("ASSIGN");
      var _hoisted_80 = {
        key: 1
      };
      var _hoisted_81 = {
        class: "d-flex justify-content-between mb-2"
      };
      var _hoisted_82 = _withScopeId(() => createElementVNode("h1", null, "Projects", -1));
      var _hoisted_83 = {
        class: "d-flex justify-content-end mb-2"
      };
      var _hoisted_84 = createTextVNode("RUN OPTIMIZATION");
      var _hoisted_85 = createTextVNode("RUN OPTIMIZATION");
      var _hoisted_86 = _withScopeId(() => createElementVNode("p", {
        class: "text-right"
      }, [createTextVNode(" OSC cannot be assigned to multiple projects at the same time"), createElementVNode("br"), createTextVNode(" OSC cannot be assigned to more projects than their max"), createElementVNode("br"), createTextVNode(" Each project can only have 1 OSC"), createElementVNode("br"), createTextVNode(" Optimizes for the highest aggregate score across all projects ")], -1));
      var _hoisted_87 = {
        class: "mb-3"
      };
      var _hoisted_88 = createTextVNode("Unassigned Projects");
      var _hoisted_89 = createTextVNode("Assigned Projects");
      var _hoisted_90 = {
        key: 0,
        class: "d-flex justify-content-between align-items-center w-100"
      };
      var _hoisted_91 = {
        class: "pl-2"
      };
      var _hoisted_92 = createTextVNode("ASSIGN");
      var _hoisted_93 = {
        key: 1,
        class: "text-danger"
      };
      var _hoisted_94 = {
        class: "d-flex align-items-center h-100"
      };
      var _hoisted_95 = createTextVNode("MANAGE");
      var _hoisted_96 = {
        class: "d-flex align-items-center h-100"
      };
      var _hoisted_97 = createTextVNode("MANAGE");
      var _hoisted_98 = {
        key: 2,
        class: "alert alert-danger mt-5"
      };
      var _hoisted_99 = _withScopeId(() => createElementVNode("p", {
        class: "text-danger",
        role: "button",
        "data-toggle": "collapse",
        "data-target": "#collapseExcludedOsc",
        "aria-expanded": "false",
        "aria-controls": "collapseExcludedOsc"
      }, " There are problems with some OSCs and they are not included in any matching or other screens. Click here to expand the list. ", -1));
      var _hoisted_100 = {
        class: "collapse mt-2",
        id: "collapseExcludedOsc"
      };
      var _hoisted_101 = ["href"];
      var _hoisted_102 = {
        key: 0
      };
      var _hoisted_103 = {
        key: 1
      };
      var _hoisted_104 = {
        key: 2
      };
      var _hoisted_105 = {
        key: 2,
        class: "alert alert-danger",
        role: "alert"
      };
      var _hoisted_106 = _withScopeId(() => createElementVNode("p", {
        class: "text-center"
      }, "You are about to assign a person to a project. Please confirm this below.", -1));
      var _hoisted_107 = {
        class: "text-center"
      };
      var _hoisted_108 = _withScopeId(() => createElementVNode("p", {
        class: "text-center mt-4"
      }, "will be assigned to", -1));
      var _hoisted_109 = {
        class: "text-center"
      };
      var _hoisted_110 = _withScopeId(() => createElementVNode("p", {
        class: "text-center"
      }, "You are about to assign a person to a project. Please confirm this below.", -1));
      var _hoisted_111 = {
        class: "text-center"
      };
      var _hoisted_112 = _withScopeId(() => createElementVNode("p", {
        class: "text-center mt-4"
      }, "will be assigned to", -1));
      var _hoisted_113 = {
        class: "text-center"
      };
      var _hoisted_114 = {
        class: "grid-obsidian grid-bordered grid-striped"
      };
      var _hoisted_115 = _withScopeId(() => createElementVNode("div", {
        class: "grid-heading"
      }, [createElementVNode("div", {
        class: "grid-column-heading"
      }, [createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Name")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Gender")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Location")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 20%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Day")]), createElementVNode("div", {
        class: "grid-column-header",
        style: {
          "flex": "1 1 10%"
        }
      }, [createElementVNode("span", {
        class: "grid-column-title stretched-link"
      }, "Time")])])], -1));
      var _hoisted_116 = {
        class: "grid-body"
      };
      var _hoisted_117 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var _hoisted_118 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_119 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_120 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_121 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 20%"
        }
      };
      var _hoisted_122 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_123 = {
        class: "grid-cell",
        role: "gridcell",
        style: {
          "flex": "1 1 10%"
        }
      };
      var _hoisted_124 = {
        class: "d-flex flex-column flex-lg-row"
      };
      var _hoisted_125 = ["innerHTML"];
      var _hoisted_126 = ["innerHTML"];
      var _hoisted_127 = ["innerHTML"];
      var _hoisted_128 = _withScopeId(() => createElementVNode("div", {
        style: {
          "height": "0px"
        }
      }, null, -1));
      var script = exports('default', defineComponent({
        name: 'matchingTool',
        setup(__props) {
          var config = useConfigurationValues();
          var invokeBlockAction = useInvokeBlockAction();
          var errorMessage = ref("");
          var projectsGridData;
          var unasignedProjects = [];
          var asignedProjects = [];
          var onSiteCoordinators = [];
          var onSiteCoordinatorsGridData;
          var assignedProjectsGridDataSource = ref();
          var unassignedProjectsGridDataSource = ref();
          var unnasignedProjectsSelected = ref(true);
          var selectedProject = ref(null);
          var oscsGridDataSource = ref();
          var runningOptimizations = ref(false);
          var isSuggestedOscAssignModalVisible = ref(false);
          var isSuggestedOscAssignModalSaving = ref(false);
          var suggestedOscModalProjectSelected = ref();
          var selectedOsc = ref(null);
          var isRegularOscAssignModalVisible = ref(false);
          var isRegularOscAssignModalSaving = ref(false);
          var regularOscAssignModalPersonSelected = ref();
          var selectedOscProjects = ref();
          var selectedOscForProjects = ref();
          var isOscAssignedProjectsModalVisible = ref(false);
          var excludedOnSiteCoordinators = ref([]);
          var oscAssignWarnings = ref([]);
          function loadProjectsGridData(_x) {
            return _loadProjectsGridData.apply(this, arguments);
          }
          function _loadProjectsGridData() {
            _loadProjectsGridData = _asyncToGenerator(function* (assigned) {
              var result = yield invokeBlockAction("GetProjectsRowData", {
                assigned
              });
              if (result.isSuccess && result.data) {
                if (assigned === true) {
                  asignedProjects = result.data.rows;
                } else if (assigned === false) {
                  unasignedProjects = result.data.rows;
                }
                projectsGridData = reactive(result.data);
                return projectsGridData;
              } else {
                var _result$errorMessage;
                var _errorMessage = (_result$errorMessage = result.errorMessage) !== null && _result$errorMessage !== void 0 ? _result$errorMessage : "Unknown error while trying to load projects grid data.";
                setErrorMessage(_errorMessage);
                throw new Error(_errorMessage);
              }
            });
            return _loadProjectsGridData.apply(this, arguments);
          }
          function loadOnSiteCoordinatorsGridData(_x2) {
            return _loadOnSiteCoordinatorsGridData.apply(this, arguments);
          }
          function _loadOnSiteCoordinatorsGridData() {
            _loadOnSiteCoordinatorsGridData = _asyncToGenerator(function* (projectId) {
              var result = yield invokeBlockAction("GetOnSiteCoordinatorsRowData", {
                projectId
              });
              if (result.isSuccess && result.data) {
                onSiteCoordinators = result.data.rows;
                onSiteCoordinatorsGridData = reactive(result.data);
                return onSiteCoordinatorsGridData;
              } else {
                var _result$errorMessage2;
                var _errorMessage2 = (_result$errorMessage2 = result.errorMessage) !== null && _result$errorMessage2 !== void 0 ? _result$errorMessage2 : "Unknown error while trying to load OSCs grid data.";
                setErrorMessage(_errorMessage2);
                throw new Error(_errorMessage2);
              }
            });
            return _loadOnSiteCoordinatorsGridData.apply(this, arguments);
          }
          function getExcludedOnSiteCoordinators() {
            return _getExcludedOnSiteCoordinators.apply(this, arguments);
          }
          function _getExcludedOnSiteCoordinators() {
            _getExcludedOnSiteCoordinators = _asyncToGenerator(function* () {
              var result = yield invokeBlockAction("GetExcludedOnSiteCoordinators");
              if (result.isSuccess && result.data) {
                excludedOnSiteCoordinators.value = result.data;
                return reactive(result.data);
              } else {
                var _result$errorMessage3;
                var _errorMessage3 = (_result$errorMessage3 = result.errorMessage) !== null && _result$errorMessage3 !== void 0 ? _result$errorMessage3 : "Unknown error while trying to get excluded OSCs.";
                setErrorMessage(_errorMessage3);
                throw new Error(_errorMessage3);
              }
            });
            return _getExcludedOnSiteCoordinators.apply(this, arguments);
          }
          function getSelectedOnSiteCoordinator(_x3, _x4) {
            return _getSelectedOnSiteCoordinator.apply(this, arguments);
          }
          function _getSelectedOnSiteCoordinator() {
            _getSelectedOnSiteCoordinator = _asyncToGenerator(function* (projectId, personId) {
              var result = yield invokeBlockAction("GetSelectedOnSiteCoordinator", {
                projectId,
                personId
              });
              if (result.isSuccess && result.data) {
                selectedOsc.value = result.data;
                return reactive(result.data);
              } else {
                var _result$errorMessage4;
                var _errorMessage4 = (_result$errorMessage4 = result.errorMessage) !== null && _result$errorMessage4 !== void 0 ? _result$errorMessage4 : "Unknown error while trying to get selected OSC.";
                setErrorMessage(_errorMessage4);
                throw new Error(_errorMessage4);
              }
            });
            return _getSelectedOnSiteCoordinator.apply(this, arguments);
          }
          function runOptimizations() {
            return _runOptimizations.apply(this, arguments);
          }
          function _runOptimizations() {
            _runOptimizations = _asyncToGenerator(function* () {
              runningOptimizations.value = true;
              var result = yield invokeBlockAction("RunOptimizations");
              if (result.isSuccess && result.data) {
                unasignedProjects = result.data.rows;
                projectsGridData = reactive(result.data);
                runningOptimizations.value = false;
                return projectsGridData;
              } else {
                var _result$errorMessage5;
                var _errorMessage5 = (_result$errorMessage5 = result.errorMessage) !== null && _result$errorMessage5 !== void 0 ? _result$errorMessage5 : "Unknown error while trying to run optimizations.";
                setErrorMessage(_errorMessage5);
                throw new Error(_errorMessage5);
              }
            });
            return _runOptimizations.apply(this, arguments);
          }
          function assignOnSiteCoordinator(_x5, _x6) {
            return _assignOnSiteCoordinator.apply(this, arguments);
          }
          function _assignOnSiteCoordinator() {
            _assignOnSiteCoordinator = _asyncToGenerator(function* (projectId, oscId) {
              var result = yield invokeBlockAction("AssignOnSiteCoordinator", {
                projectId,
                oscId
              });
              if (result.isSuccess) {
                return;
              } else {
                var _result$errorMessage6;
                var _errorMessage6 = (_result$errorMessage6 = result.errorMessage) !== null && _result$errorMessage6 !== void 0 ? _result$errorMessage6 : "Unknown error while trying to assign OSC to project.";
                setErrorMessage(_errorMessage6);
                throw new Error(_errorMessage6);
              }
            });
            return _assignOnSiteCoordinator.apply(this, arguments);
          }
          function validateAssignOnSiteCoordinator(_x7, _x8) {
            return _validateAssignOnSiteCoordinator.apply(this, arguments);
          }
          function _validateAssignOnSiteCoordinator() {
            _validateAssignOnSiteCoordinator = _asyncToGenerator(function* (projectId, oscId) {
              var result = yield invokeBlockAction("ValidateAssignOnSiteCoordinator", {
                projectId,
                oscId
              });
              if (result.isSuccess && result.data) {
                oscAssignWarnings.value = result.data;
                return result.data;
              } else {
                var _result$errorMessage7;
                var _errorMessage7 = (_result$errorMessage7 = result.errorMessage) !== null && _result$errorMessage7 !== void 0 ? _result$errorMessage7 : "Unknown error while trying to validate assign OSC to project.";
                setErrorMessage(_errorMessage7);
                throw new Error(_errorMessage7);
              }
            });
            return _validateAssignOnSiteCoordinator.apply(this, arguments);
          }
          function getOnSiteCoordinatorProjects(_x9) {
            return _getOnSiteCoordinatorProjects.apply(this, arguments);
          }
          function _getOnSiteCoordinatorProjects() {
            _getOnSiteCoordinatorProjects = _asyncToGenerator(function* (personId) {
              var result = yield invokeBlockAction("GetOnSiteCoordinatorProjects", {
                personId
              });
              if (result.isSuccess && result.data) {
                selectedOscProjects.value = result.data;
                return reactive(result.data);
              } else {
                var _result$errorMessage8;
                var _errorMessage8 = (_result$errorMessage8 = result.errorMessage) !== null && _result$errorMessage8 !== void 0 ? _result$errorMessage8 : "Unknown error while trying to get OSC projects.";
                setErrorMessage(_errorMessage8);
                throw new Error(_errorMessage8);
              }
            });
            return _getOnSiteCoordinatorProjects.apply(this, arguments);
          }
          function onRunOptimizationsClick() {
            unassignedProjectsGridDataSource.value = runOptimizations();
          }
          function onProjectEditClick(key) {
            if (unnasignedProjectsSelected.value) {
              var _unasignedProjects$fi;
              oscsGridDataSource.value = loadOnSiteCoordinatorsGridData(key);
              selectedProject.value = (_unasignedProjects$fi = unasignedProjects.find(p => String(p.id) == key)) !== null && _unasignedProjects$fi !== void 0 ? _unasignedProjects$fi : null;
              setTooltips();
            } else {
              var _asignedProjects$find;
              selectedProject.value = (_asignedProjects$find = asignedProjects.find(p => String(p.id) == key)) !== null && _asignedProjects$find !== void 0 ? _asignedProjects$find : null;
              if (selectedProject.value && selectedProject.value.selectedOscId) {
                getSelectedOnSiteCoordinator(selectedProject.value.id, selectedProject.value.selectedOscId).then(() => {
                  setTooltips();
                });
              }
            }
          }
          function onSuggestedOscAssignClick(key) {
            oscAssignWarnings.value = [];
            var project = unasignedProjects.find(p => p.id == key && p.suggestedOscId);
            if (project) {
              project.id && project.suggestedOscId && validateAssignOnSiteCoordinator(project.id, project.suggestedOscId);
              suggestedOscModalProjectSelected.value = project;
              isSuggestedOscAssignModalVisible.value = true;
            }
          }
          function onSeggestedOscAssignSaveClick() {
            isSuggestedOscAssignModalSaving.value = true;
            if (suggestedOscModalProjectSelected.value && suggestedOscModalProjectSelected.value.suggestedOscId) {
              assignOnSiteCoordinator(suggestedOscModalProjectSelected.value.id, suggestedOscModalProjectSelected.value.suggestedOscId).then(() => {
                isSuggestedOscAssignModalVisible.value = false;
                unnasignedProjectsSelected.value = false;
                if (suggestedOscModalProjectSelected.value && suggestedOscModalProjectSelected.value.suggestedOscId) {
                  getSelectedOnSiteCoordinator(suggestedOscModalProjectSelected.value.id, suggestedOscModalProjectSelected.value.suggestedOscId).then(() => {
                    setTooltips();
                  });
                }
                assignedProjectsGridDataSource.value = loadProjectsGridData(true);
                unassignedProjectsGridDataSource.value = loadProjectsGridData(false);
              }).finally(() => {
                isSuggestedOscAssignModalSaving.value = false;
              });
            } else {
              isSuggestedOscAssignModalVisible.value = false;
            }
          }
          function onRegularOscAssignClick(key) {
            oscAssignWarnings.value = [];
            var osc = onSiteCoordinators.find(p => p.id == key);
            if (osc) {
              var _selectedProject$valu;
              ((_selectedProject$valu = selectedProject.value) === null || _selectedProject$valu === void 0 ? void 0 : _selectedProject$valu.id) && osc.id && validateAssignOnSiteCoordinator(selectedProject.value.id, osc.id);
              regularOscAssignModalPersonSelected.value = osc;
              isRegularOscAssignModalVisible.value = true;
            }
          }
          function onRegularOscAssignSaveClick() {
            isRegularOscAssignModalSaving.value = true;
            if (selectedProject.value && regularOscAssignModalPersonSelected.value) {
              assignOnSiteCoordinator(selectedProject.value.id, regularOscAssignModalPersonSelected.value.id).then(() => {
                isRegularOscAssignModalVisible.value = false;
                unnasignedProjectsSelected.value = false;
                if (selectedProject.value && regularOscAssignModalPersonSelected.value) {
                  getSelectedOnSiteCoordinator(selectedProject.value.id, regularOscAssignModalPersonSelected.value.id).then(() => {
                    setTooltips();
                  });
                }
                assignedProjectsGridDataSource.value = loadProjectsGridData(true);
                unassignedProjectsGridDataSource.value = loadProjectsGridData(false);
              }).finally(() => {
                isRegularOscAssignModalSaving.value = false;
              });
            } else {
              isRegularOscAssignModalVisible.value = false;
            }
          }
          function selectUnassignedProjects() {
            unnasignedProjectsSelected.value = true;
          }
          function selectAssignedProjects() {
            if (assignedProjectsGridDataSource.value === undefined) {
              assignedProjectsGridDataSource.value = loadProjectsGridData(true);
            }
            unnasignedProjectsSelected.value = false;
          }
          function onOscProjectsClick(key, currentProjects) {
            if (currentProjects) {
              var _onSiteCoordinators$f;
              selectedOscForProjects.value = (_onSiteCoordinators$f = onSiteCoordinators.find(p => p.id == key)) !== null && _onSiteCoordinators$f !== void 0 ? _onSiteCoordinators$f : null;
              getOnSiteCoordinatorProjects(key).then(() => {
                isOscAssignedProjectsModalVisible.value = true;
                setTooltips();
              });
            }
          }
          function onGoBackClick() {
            oscsGridDataSource.value = undefined;
            selectedProject.value = null;
            selectedOsc.value = null;
          }
          var closeSuggestedOscAssignModal = () => {
            isSuggestedOscAssignModalVisible.value = false;
            unnasignedProjectsSelected.value = true;
            oscsGridDataSource.value = undefined;
            selectedProject.value = null;
            selectedOsc.value = null;
          };
          var closeRegularOscAssignModal = () => {
            isRegularOscAssignModalVisible.value = false;
          };
          var closeOscAssignedProjectsModal = () => {
            isOscAssignedProjectsModalVisible.value = false;
          };
          function getDayMatchClass(days, day, projectDay) {
            if (days && day && projectDay && days.some(x => x.toLowerCase() == day.toLowerCase() && x.toLowerCase() == projectDay.toLowerCase())) {
              return "day-time-container exact-match {}";
            } else if (days && day && days.some(x => x.toLowerCase() == day.toLowerCase())) {
              return "day-time-container match {}";
            } else {
              return "day-time-container";
            }
          }
          function getTimeMatchClass(times, time, projectTimes) {
            if (times && time && projectTimes && times.some(x => x.toLowerCase() == time.toLowerCase() && projectTimes.some(y => y.toLowerCase() == x.toLowerCase()))) {
              return "day-time-container time exact-match {}";
            } else if (times && time && times.some(x => x.toLowerCase() == time.toLowerCase())) {
              return "day-time-container time match {}";
            } else {
              return "day-time-container time";
            }
          }
          function getTimeOfDayIcon(time) {
            switch (time) {
              case "Morning":
                return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" fill=\"currentColor\" class=\"bi bi-sunrise\" viewBox=\"0 0 16 16\"><path d=\"M7.646 1.146a.5.5 0 0 1 .708 0l1.5 1.5a.5.5 0 0 1-.708.708L8.5 2.707V4.5a.5.5 0 0 1-1 0V2.707l-.646.647a.5.5 0 1 1-.708-.708zM2.343 4.343a.5.5 0 0 1 .707 0l1.414 1.414a.5.5 0 0 1-.707.707L2.343 5.05a.5.5 0 0 1 0-.707m11.314 0a.5.5 0 0 1 0 .707l-1.414 1.414a.5.5 0 1 1-.707-.707l1.414-1.414a.5.5 0 0 1 .707 0M8 7a3 3 0 0 1 2.599 4.5H5.4A3 3 0 0 1 8 7m3.71 4.5a4 4 0 1 0-7.418 0H.499a.5.5 0 0 0 0 1h15a.5.5 0 0 0 0-1h-3.79zM0 10a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2A.5.5 0 0 1 0 10m13 0a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2a.5.5 0 0 1-.5-.5\"/></svg>";
              case "Afternoon":
                return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" fill=\"currentColor\" class=\"bi bi-sun\" viewBox=\"0 0 16 16\"><path d=\"M8 11a3 3 0 1 1 0-6 3 3 0 0 1 0 6m0 1a4 4 0 1 0 0-8 4 4 0 0 0 0 8M8 0a.5.5 0 0 1 .5.5v2a.5.5 0 0 1-1 0v-2A.5.5 0 0 1 8 0m0 13a.5.5 0 0 1 .5.5v2a.5.5 0 0 1-1 0v-2A.5.5 0 0 1 8 13m8-5a.5.5 0 0 1-.5.5h-2a.5.5 0 0 1 0-1h2a.5.5 0 0 1 .5.5M3 8a.5.5 0 0 1-.5.5h-2a.5.5 0 0 1 0-1h2A.5.5 0 0 1 3 8m10.657-5.657a.5.5 0 0 1 0 .707l-1.414 1.415a.5.5 0 1 1-.707-.708l1.414-1.414a.5.5 0 0 1 .707 0m-9.193 9.193a.5.5 0 0 1 0 .707L3.05 13.657a.5.5 0 0 1-.707-.707l1.414-1.414a.5.5 0 0 1 .707 0m9.193 2.121a.5.5 0 0 1-.707 0l-1.414-1.414a.5.5 0 0 1 .707-.707l1.414 1.414a.5.5 0 0 1 0 .707M4.464 4.465a.5.5 0 0 1-.707 0L2.343 3.05a.5.5 0 1 1 .707-.707l1.414 1.414a.5.5 0 0 1 0 .708\"/></svg>";
              case "Evening":
                return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" fill=\"currentColor\" class=\"bi bi-sunset\" viewBox=\"0 0 16 16\"><path d=\"M7.646 4.854a.5.5 0 0 0 .708 0l1.5-1.5a.5.5 0 0 0-.708-.708l-.646.647V1.5a.5.5 0 0 0-1 0v1.793l-.646-.647a.5.5 0 1 0-.708.708zm-5.303-.51a.5.5 0 0 1 .707 0l1.414 1.413a.5.5 0 0 1-.707.707L2.343 5.05a.5.5 0 0 1 0-.707zm11.314 0a.5.5 0 0 1 0 .706l-1.414 1.414a.5.5 0 1 1-.707-.707l1.414-1.414a.5.5 0 0 1 .707 0zM8 7a3 3 0 0 1 2.599 4.5H5.4A3 3 0 0 1 8 7m3.71 4.5a4 4 0 1 0-7.418 0H.499a.5.5 0 0 0 0 1h15a.5.5 0 0 0 0-1h-3.79zM0 10a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2A.5.5 0 0 1 0 10m13 0a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2a.5.5 0 0 1-.5-.5\"/></svg>";
              default:
                return "";
            }
          }
          function getGenderClassForOscAssignedProjects(gender) {
            var _selectedOscForProjec;
            return "match-item" + (gender == Gender.Unknown || ((_selectedOscForProjec = selectedOscForProjects.value) === null || _selectedOscForProjec === void 0 ? void 0 : _selectedOscForProjec.gender) == gender ? " match" : "");
          }
          function getLocationClassForOscAssignedProjects(location) {
            var _selectedOscForProjec2;
            return "match-item" + (!location || ((_selectedOscForProjec2 = selectedOscForProjects.value) === null || _selectedOscForProjec2 === void 0 ? void 0 : _selectedOscForProjec2.location) == location ? " match" : "");
          }
          function getDayMatchClassForOscAssignedProjects(time, projectDay) {
            var _selectedOscForProjec3;
            return getDayMatchClass((_selectedOscForProjec3 = selectedOscForProjects.value) === null || _selectedOscForProjec3 === void 0 ? void 0 : _selectedOscForProjec3.dayPreference, time, projectDay);
          }
          function getTimeMatchClassForOscAssignedProjects(time, projectTimes) {
            var _selectedOscForProjec4;
            return getTimeMatchClass((_selectedOscForProjec4 = selectedOscForProjects.value) === null || _selectedOscForProjec4 === void 0 ? void 0 : _selectedOscForProjec4.timePreference, time, projectTimes);
          }
          function setErrorMessage(message) {
            errorMessage.value = message;
            setTimeout(() => {
              if (errorMessage) {
                errorMessage.value = "";
              }
            }, 10000);
          }
          function setTooltips() {
            setTimeout(() => {
              var $ = window["$"];
              $('[data-toggle="tooltip"]').tooltip();
            }, 300);
          }
          unassignedProjectsGridDataSource.value = loadProjectsGridData(false);
          getExcludedOnSiteCoordinators();
          return (_ctx, _cache) => {
            return openBlock(), createBlock(unref(Block), {
              title: "OSC Matching Tool"
            }, {
              default: withCtx(() => {
                var _selectedProject$valu2, _selectedProject$valu3, _selectedProject$valu4, _selectedProject$valu5, _selectedProject$valu6, _selectedProject$valu7, _selectedProject$valu8, _selectedProject$valu9, _selectedProject$valu10, _selectedProject$valu11, _selectedProject$valu12, _selectedProject$valu13, _selectedProject$valu14, _selectedProject$valu15, _selectedProject$valu16, _selectedProject$valu17, _selectedProject$valu18, _selectedProject$valu19, _selectedProject$valu20, _selectedProject$valu21, _selectedProject$valu22, _selectedProject$valu23, _selectedProject$valu24, _selectedProject$valu25, _selectedProject$valu26, _selectedProject$valu27, _selectedProject$valu28, _selectedProject$valu29, _selectedProject$valu30, _selectedOsc$value$ex, _selectedOsc$value, _selectedProject$valu31, _selectedOsc$value2, _selectedProject$valu32, _selectedOsc$value3, _selectedProject$valu33, _selectedOsc$value4, _selectedProject$valu34, _selectedOsc$value5, _selectedProject$valu35, _selectedOsc$value6, _selectedProject$valu36, _selectedOsc$value7, _selectedProject$valu37, _selectedProject$valu38, _selectedProject$valu39, _selectedProject$valu40, _unref$onSiteCoordina, _unref$projectsGridDe, _unref$projectsGridDe2;
                return [errorMessage.value ? (openBlock(), createBlock(unref(NotificationBox), {
                  key: 0,
                  alertType: "danger"
                }, {
                  default: withCtx(() => [createTextVNode(toDisplayString(errorMessage.value), 1)]),
                  _: 1
                })) : createCommentVNode("v-if", true), unref(config).isInitialConfigSet ? (openBlock(), createElementBlock("div", _hoisted_1, [selectedProject.value ? (openBlock(), createElementBlock("div", _hoisted_2, [createElementVNode("div", _hoisted_3, [createVNode(unref(RockButton), {
                  type: "button",
                  onClick: onGoBackClick
                }, {
                  default: withCtx(() => [_hoisted_4, _hoisted_5]),
                  _: 1
                })]), createElementVNode("div", _hoisted_6, [createElementVNode("div", _hoisted_7, [createElementVNode("h2", _hoisted_8, toDisplayString(selectedProject.value.name), 1), createElementVNode("h3", _hoisted_9, toDisplayString(selectedProject.value.partner), 1)]), createElementVNode("div", _hoisted_10, [createElementVNode("div", _hoisted_11, [createElementVNode("div", _hoisted_12, [createElementVNode("div", _hoisted_13, [_hoisted_14, createElementVNode("h5", _hoisted_15, toDisplayString(selectedProject.value.gender != unref(Gender).Unknown ? selectedProject.value.genderString : 'Not Specified'), 1)]), createElementVNode("div", _hoisted_16, [_hoisted_17, createElementVNode("h5", _hoisted_18, toDisplayString((_selectedProject$valu2 = selectedProject.value.location) !== null && _selectedProject$valu2 !== void 0 ? _selectedProject$valu2 : 'Not Provided'), 1)]), createElementVNode("div", _hoisted_19, [_hoisted_20, createElementVNode("h5", _hoisted_21, toDisplayString(selectedProject.value.fullDate), 1)]), createElementVNode("div", _hoisted_22, [_hoisted_23, createElementVNode("h5", _hoisted_24, toDisplayString(selectedProject.value.time), 1)])])])])]), createElementVNode("div", _hoisted_25, [createElementVNode("div", _hoisted_26, [_hoisted_27, createElementVNode("div", _hoisted_28, [_hoisted_29, createElementVNode("div", _hoisted_30, [_hoisted_31, createElementVNode("div", _hoisted_32, [createElementVNode("span", _hoisted_33, toDisplayString(selectedProject.value.gender != unref(Gender).Unknown ? selectedProject.value.genderString : 'Not Specified'), 1)]), createElementVNode("div", _hoisted_34, [createElementVNode("span", _hoisted_35, toDisplayString((_selectedProject$valu3 = selectedProject.value.location) !== null && _selectedProject$valu3 !== void 0 ? _selectedProject$valu3 : 'Not Provided'), 1)]), createElementVNode("div", _hoisted_36, [createElementVNode("div", _hoisted_37, [createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu4 = (_selectedProject$valu5 = selectedProject.value) === null || _selectedProject$valu5 === void 0 ? void 0 : _selectedProject$valu5.day) !== null && _selectedProject$valu4 !== void 0 ? _selectedProject$valu4 : ''], 'Monday', (_selectedProject$valu6 = selectedProject.value) === null || _selectedProject$valu6 === void 0 ? void 0 : _selectedProject$valu6.day))
                }, "M", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu7 = (_selectedProject$valu8 = selectedProject.value) === null || _selectedProject$valu8 === void 0 ? void 0 : _selectedProject$valu8.day) !== null && _selectedProject$valu7 !== void 0 ? _selectedProject$valu7 : ''], 'Tuesday', (_selectedProject$valu9 = selectedProject.value) === null || _selectedProject$valu9 === void 0 ? void 0 : _selectedProject$valu9.day))
                }, "T", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu10 = (_selectedProject$valu11 = selectedProject.value) === null || _selectedProject$valu11 === void 0 ? void 0 : _selectedProject$valu11.day) !== null && _selectedProject$valu10 !== void 0 ? _selectedProject$valu10 : ''], 'Wednesday', (_selectedProject$valu12 = selectedProject.value) === null || _selectedProject$valu12 === void 0 ? void 0 : _selectedProject$valu12.day))
                }, "W", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu13 = (_selectedProject$valu14 = selectedProject.value) === null || _selectedProject$valu14 === void 0 ? void 0 : _selectedProject$valu14.day) !== null && _selectedProject$valu13 !== void 0 ? _selectedProject$valu13 : ''], 'Thursday', (_selectedProject$valu15 = selectedProject.value) === null || _selectedProject$valu15 === void 0 ? void 0 : _selectedProject$valu15.day))
                }, "T", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu16 = (_selectedProject$valu17 = selectedProject.value) === null || _selectedProject$valu17 === void 0 ? void 0 : _selectedProject$valu17.day) !== null && _selectedProject$valu16 !== void 0 ? _selectedProject$valu16 : ''], 'Friday', (_selectedProject$valu18 = selectedProject.value) === null || _selectedProject$valu18 === void 0 ? void 0 : _selectedProject$valu18.day))
                }, "F", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu19 = (_selectedProject$valu20 = selectedProject.value) === null || _selectedProject$valu20 === void 0 ? void 0 : _selectedProject$valu20.day) !== null && _selectedProject$valu19 !== void 0 ? _selectedProject$valu19 : ''], 'Saturday', (_selectedProject$valu21 = selectedProject.value) === null || _selectedProject$valu21 === void 0 ? void 0 : _selectedProject$valu21.day))
                }, "S", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass([(_selectedProject$valu22 = (_selectedProject$valu23 = selectedProject.value) === null || _selectedProject$valu23 === void 0 ? void 0 : _selectedProject$valu23.day) !== null && _selectedProject$valu22 !== void 0 ? _selectedProject$valu22 : ''], 'Sunday', (_selectedProject$valu24 = selectedProject.value) === null || _selectedProject$valu24 === void 0 ? void 0 : _selectedProject$valu24.day))
                }, "S", 2)])]), createElementVNode("div", _hoisted_38, [createElementVNode("div", _hoisted_39, [createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Morning'),
                  class: normalizeClass(getTimeMatchClass((_selectedProject$valu25 = selectedProject.value) === null || _selectedProject$valu25 === void 0 ? void 0 : _selectedProject$valu25.timeOfDay, 'Morning', (_selectedProject$valu26 = selectedProject.value) === null || _selectedProject$valu26 === void 0 ? void 0 : _selectedProject$valu26.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Morning Session: 8am - 12pm"
                }, null, 10, _hoisted_40), createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Afternoon'),
                  class: normalizeClass(getTimeMatchClass((_selectedProject$valu27 = selectedProject.value) === null || _selectedProject$valu27 === void 0 ? void 0 : _selectedProject$valu27.timeOfDay, 'Afternoon', (_selectedProject$valu28 = selectedProject.value) === null || _selectedProject$valu28 === void 0 ? void 0 : _selectedProject$valu28.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Afternoon Session: 12pm - 4pm"
                }, null, 10, _hoisted_41), createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Evening'),
                  class: normalizeClass(getTimeMatchClass((_selectedProject$valu29 = selectedProject.value) === null || _selectedProject$valu29 === void 0 ? void 0 : _selectedProject$valu29.timeOfDay, 'Evening', (_selectedProject$valu30 = selectedProject.value) === null || _selectedProject$valu30 === void 0 ? void 0 : _selectedProject$valu30.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Evening Session: 4pm - 9pm"
                }, null, 10, _hoisted_42)])]), _hoisted_43, _hoisted_44, _hoisted_45]), _hoisted_46])])]), selectedOsc.value ? (openBlock(), createElementBlock("div", _hoisted_47, [_hoisted_48, createElementVNode("div", _hoisted_49, [createElementVNode("div", _hoisted_50, [_hoisted_51, createElementVNode("div", _hoisted_52, [createElementVNode("div", _hoisted_53, [createElementVNode("span", {
                  "data-toggle": "tooltip",
                  title: (_selectedOsc$value$ex = selectedOsc.value.extraInfo) !== null && _selectedOsc$value$ex !== void 0 ? _selectedOsc$value$ex : undefined
                }, [selectedOsc.value.extraInfo ? (openBlock(), createElementBlock("i", _hoisted_55)) : createCommentVNode("v-if", true), createTextVNode(toDisplayString(selectedOsc.value.name), 1)], 8, _hoisted_54)]), createElementVNode("div", _hoisted_56, [createElementVNode("span", {
                  class: normalizeClass('match-item' + (!selectedProject.value || selectedProject.value.gender == unref(Gender).Unknown || selectedOsc.value.gender == selectedProject.value.gender ? ' match' : ''))
                }, toDisplayString(selectedOsc.value.gender != unref(Gender).Unknown ? selectedOsc.value.genderString : 'Not Specified'), 3)]), createElementVNode("div", _hoisted_57, [selectedOsc.value.location ? (openBlock(), createElementBlock("span", {
                  key: 0,
                  class: normalizeClass('match-item' + (!selectedProject.value || !selectedProject.value.location || selectedOsc.value.location == selectedProject.value.location ? ' match' : ''))
                }, toDisplayString(selectedOsc.value.location), 3)) : createCommentVNode("v-if", true)]), createElementVNode("div", _hoisted_58, [createElementVNode("div", _hoisted_59, [createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value = selectedOsc.value) === null || _selectedOsc$value === void 0 ? void 0 : _selectedOsc$value.dayPreference, 'Monday', (_selectedProject$valu31 = selectedProject.value) === null || _selectedProject$valu31 === void 0 ? void 0 : _selectedProject$valu31.day))
                }, "M", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value2 = selectedOsc.value) === null || _selectedOsc$value2 === void 0 ? void 0 : _selectedOsc$value2.dayPreference, 'Tuesday', (_selectedProject$valu32 = selectedProject.value) === null || _selectedProject$valu32 === void 0 ? void 0 : _selectedProject$valu32.day))
                }, "T", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value3 = selectedOsc.value) === null || _selectedOsc$value3 === void 0 ? void 0 : _selectedOsc$value3.dayPreference, 'Wednesday', (_selectedProject$valu33 = selectedProject.value) === null || _selectedProject$valu33 === void 0 ? void 0 : _selectedProject$valu33.day))
                }, "W", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value4 = selectedOsc.value) === null || _selectedOsc$value4 === void 0 ? void 0 : _selectedOsc$value4.dayPreference, 'Thursday', (_selectedProject$valu34 = selectedProject.value) === null || _selectedProject$valu34 === void 0 ? void 0 : _selectedProject$valu34.day))
                }, "T", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value5 = selectedOsc.value) === null || _selectedOsc$value5 === void 0 ? void 0 : _selectedOsc$value5.dayPreference, 'Friday', (_selectedProject$valu35 = selectedProject.value) === null || _selectedProject$valu35 === void 0 ? void 0 : _selectedProject$valu35.day))
                }, "F", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value6 = selectedOsc.value) === null || _selectedOsc$value6 === void 0 ? void 0 : _selectedOsc$value6.dayPreference, 'Saturday', (_selectedProject$valu36 = selectedProject.value) === null || _selectedProject$valu36 === void 0 ? void 0 : _selectedProject$valu36.day))
                }, "S", 2), createElementVNode("span", {
                  class: normalizeClass(getDayMatchClass((_selectedOsc$value7 = selectedOsc.value) === null || _selectedOsc$value7 === void 0 ? void 0 : _selectedOsc$value7.dayPreference, 'Sunday', (_selectedProject$valu37 = selectedProject.value) === null || _selectedProject$valu37 === void 0 ? void 0 : _selectedProject$valu37.day))
                }, "S", 2)])]), createElementVNode("div", _hoisted_60, [createElementVNode("div", _hoisted_61, [createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Morning'),
                  class: normalizeClass(getTimeMatchClass(selectedOsc.value.timePreference, 'Morning', (_selectedProject$valu38 = selectedProject.value) === null || _selectedProject$valu38 === void 0 ? void 0 : _selectedProject$valu38.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Morning Session: 8am - 12pm"
                }, null, 10, _hoisted_62), createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Afternoon'),
                  class: normalizeClass(getTimeMatchClass(selectedOsc.value.timePreference, 'Afternoon', (_selectedProject$valu39 = selectedProject.value) === null || _selectedProject$valu39 === void 0 ? void 0 : _selectedProject$valu39.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Afternoon Session: 12pm - 4pm"
                }, null, 10, _hoisted_63), createElementVNode("span", {
                  innerHTML: getTimeOfDayIcon('Evening'),
                  class: normalizeClass(getTimeMatchClass(selectedOsc.value.timePreference, 'Evening', (_selectedProject$valu40 = selectedProject.value) === null || _selectedProject$valu40 === void 0 ? void 0 : _selectedProject$valu40.timeOfDay)),
                  "data-toggle": "tooltip",
                  title: "Evening Session: 4pm - 9pm"
                }, null, 10, _hoisted_64)])]), createElementVNode("div", _hoisted_65, [createElementVNode("span", {
                  class: normalizeClass(selectedOsc.value.currentProjects ? 'text-primary' : ''),
                  role: selectedOsc.value.currentProjects ? 'button' : undefined,
                  onClick: _cache[0] || (_cache[0] = $event => {
                    var _selectedOsc$value$id, _selectedOsc$value8, _selectedOsc$value$cu, _selectedOsc$value9;
                    return onOscProjectsClick((_selectedOsc$value$id = (_selectedOsc$value8 = selectedOsc.value) === null || _selectedOsc$value8 === void 0 ? void 0 : _selectedOsc$value8.id) !== null && _selectedOsc$value$id !== void 0 ? _selectedOsc$value$id : 0, (_selectedOsc$value$cu = (_selectedOsc$value9 = selectedOsc.value) === null || _selectedOsc$value9 === void 0 ? void 0 : _selectedOsc$value9.currentProjects) !== null && _selectedOsc$value$cu !== void 0 ? _selectedOsc$value$cu : 0);
                  })
                }, toDisplayString("".concat(selectedOsc.value.currentProjects, "/").concat(selectedOsc.value.maxProjects < 0 ? '-' : selectedOsc.value.maxProjects)), 11, _hoisted_66)]), createElementVNode("div", _hoisted_67, toDisplayString(selectedOsc.value.formattedMatchPercentage), 1), _hoisted_68]), _hoisted_69])])])) : createCommentVNode("v-if", true), unnasignedProjectsSelected.value ? (openBlock(), createBlock(unref(Grid), {
                  key: 1,
                  definition: (_unref$onSiteCoordina = unref(config).onSiteCoordinatorsGridDefinition) !== null && _unref$onSiteCoordina !== void 0 ? _unref$onSiteCoordina : undefined,
                  data: oscsGridDataSource.value,
                  keyField: "id",
                  itemTerm: "OSCs",
                  stickyHeader: ""
                }, {
                  default: withCtx(() => [createVNode(unref(TextColumn), {
                    name: "name",
                    field: "name",
                    title: "Name"
                  }, {
                    format: withCtx(_ref => {
                      var row = _ref.row;
                      return [createElementVNode("span", {
                        "data-toggle": "tooltip",
                        title: row.extraInfo
                      }, [row.extraInfo ? (openBlock(), createElementBlock("i", _hoisted_71)) : createCommentVNode("v-if", true), createTextVNode(toDisplayString(row.name), 1)], 8, _hoisted_70)];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "gender",
                    field: "gender",
                    title: "Gender"
                  }, {
                    format: withCtx(_ref2 => {
                      var row = _ref2.row;
                      return [createElementVNode("span", {
                        class: normalizeClass('match-item' + (!selectedProject.value || selectedProject.value.gender == unref(Gender).Unknown || row.gender == selectedProject.value.gender ? ' match' : ''))
                      }, toDisplayString(row.gender != unref(Gender).Unknown ? row.genderString : 'Not Specified'), 3)];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "location",
                    field: "location",
                    title: "Location"
                  }, {
                    format: withCtx(_ref3 => {
                      var row = _ref3.row;
                      return [row.location ? (openBlock(), createElementBlock("span", {
                        key: 0,
                        class: normalizeClass('match-item' + (!selectedProject.value || !selectedProject.value.location || row.location == selectedProject.value.location ? ' match' : ''))
                      }, toDisplayString(row.location), 3)) : createCommentVNode("v-if", true)];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "dayPreference",
                    field: "dayPreference",
                    title: "Day",
                    width: "20%"
                  }, {
                    format: withCtx(_ref4 => {
                      var _selectedProject$valu41, _selectedProject$valu42, _selectedProject$valu43, _selectedProject$valu44, _selectedProject$valu45, _selectedProject$valu46, _selectedProject$valu47;
                      var row = _ref4.row;
                      return [createElementVNode("div", _hoisted_72, [createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Monday', (_selectedProject$valu41 = selectedProject.value) === null || _selectedProject$valu41 === void 0 ? void 0 : _selectedProject$valu41.day))
                      }, "M", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Tuesday', (_selectedProject$valu42 = selectedProject.value) === null || _selectedProject$valu42 === void 0 ? void 0 : _selectedProject$valu42.day))
                      }, "T", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Wednesday', (_selectedProject$valu43 = selectedProject.value) === null || _selectedProject$valu43 === void 0 ? void 0 : _selectedProject$valu43.day))
                      }, "W", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Thursday', (_selectedProject$valu44 = selectedProject.value) === null || _selectedProject$valu44 === void 0 ? void 0 : _selectedProject$valu44.day))
                      }, "T", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Friday', (_selectedProject$valu45 = selectedProject.value) === null || _selectedProject$valu45 === void 0 ? void 0 : _selectedProject$valu45.day))
                      }, "F", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Saturday', (_selectedProject$valu46 = selectedProject.value) === null || _selectedProject$valu46 === void 0 ? void 0 : _selectedProject$valu46.day))
                      }, "S", 2), createElementVNode("span", {
                        class: normalizeClass(getDayMatchClass(row.dayPreference, 'Sunday', (_selectedProject$valu47 = selectedProject.value) === null || _selectedProject$valu47 === void 0 ? void 0 : _selectedProject$valu47.day))
                      }, "S", 2)])];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "timePreference",
                    field: "timePreference",
                    title: "Time"
                  }, {
                    format: withCtx(_ref5 => {
                      var _selectedProject$valu48, _selectedProject$valu49, _selectedProject$valu50;
                      var row = _ref5.row;
                      return [createElementVNode("div", _hoisted_73, [createElementVNode("span", {
                        innerHTML: getTimeOfDayIcon('Morning'),
                        class: normalizeClass(getTimeMatchClass(row.timePreference, 'Morning', (_selectedProject$valu48 = selectedProject.value) === null || _selectedProject$valu48 === void 0 ? void 0 : _selectedProject$valu48.timeOfDay)),
                        "data-toggle": "tooltip",
                        title: "Morning Session: 8am - 12pm"
                      }, null, 10, _hoisted_74), createElementVNode("span", {
                        innerHTML: getTimeOfDayIcon('Afternoon'),
                        class: normalizeClass(getTimeMatchClass(row.timePreference, 'Afternoon', (_selectedProject$valu49 = selectedProject.value) === null || _selectedProject$valu49 === void 0 ? void 0 : _selectedProject$valu49.timeOfDay)),
                        "data-toggle": "tooltip",
                        title: "Afternoon Session: 12pm - 4pm"
                      }, null, 10, _hoisted_75), createElementVNode("span", {
                        innerHTML: getTimeOfDayIcon('Evening'),
                        class: normalizeClass(getTimeMatchClass(row.timePreference, 'Evening', (_selectedProject$valu50 = selectedProject.value) === null || _selectedProject$valu50 === void 0 ? void 0 : _selectedProject$valu50.timeOfDay)),
                        "data-toggle": "tooltip",
                        title: "Evening Session: 4pm - 9pm"
                      }, null, 10, _hoisted_76)])];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "currentProjects",
                    field: "currentProjects",
                    title: "Projects",
                    width: "5%"
                  }, {
                    format: withCtx(_ref6 => {
                      var row = _ref6.row;
                      return [createElementVNode("span", {
                        class: normalizeClass(row.currentProjects ? 'text-primary' : ''),
                        role: row.currentProjects ? 'button' : undefined,
                        onClick: $event => onOscProjectsClick(row.id, row.currentProjects)
                      }, toDisplayString("".concat(row.currentProjects, "/").concat(row.maxProjects < 0 ? '-' : row.maxProjects)), 11, _hoisted_77)];
                    }),
                    _: 1
                  }), createVNode(unref(TextColumn), {
                    name: "matchPercentage",
                    field: "matchPercentage",
                    title: "Match Percentage",
                    width: "5%"
                  }, {
                    format: withCtx(_ref7 => {
                      var row = _ref7.row;
                      return [createElementVNode("span", null, toDisplayString(row.formattedMatchPercentage), 1)];
                    }),
                    _: 1
                  }), createVNode(unref(Column), {
                    name: "actions",
                    width: "110"
                  }, {
                    format: withCtx(_ref8 => {
                      var row = _ref8.row;
                      return [createElementVNode("div", _hoisted_78, [createVNode(unref(RockButton), {
                        type: "button",
                        class: "btn-primary btn-sm",
                        onClick: $event => onRegularOscAssignClick(row.id)
                      }, {
                        default: withCtx(() => [_hoisted_79]),
                        _: 2
                      }, 1032, ["onClick"])])];
                    }),
                    _: 1
                  })]),
                  _: 1
                }, 8, ["definition", "data"])) : createCommentVNode("v-if", true)])) : (openBlock(), createElementBlock("div", _hoisted_80, [createElementVNode("div", _hoisted_81, [_hoisted_82, createElementVNode("div", null, [createElementVNode("div", _hoisted_83, [createElementVNode("div", null, [runningOptimizations.value ? (openBlock(), createBlock(unref(RockButton), {
                  key: 0,
                  type: "button",
                  disabled: "",
                  class: "btn-primary d-flex"
                }, {
                  default: withCtx(() => [_hoisted_84, createVNode(unref(LoadingIndicator), {
                    isSmall: "",
                    class: "ml-1"
                  })]),
                  _: 1
                })) : (openBlock(), createBlock(unref(RockButton), {
                  key: 1,
                  type: "button",
                  class: "btn-primary",
                  onClick: onRunOptimizationsClick
                }, {
                  default: withCtx(() => [_hoisted_85]),
                  _: 1
                }))])]), _hoisted_86])]), createElementVNode("div", _hoisted_87, [createVNode(unref(RockButton), {
                  type: "button",
                  class: normalizeClass("mr-1 ".concat(unnasignedProjectsSelected.value ? 'btn-primary' : '')),
                  onClick: selectUnassignedProjects
                }, {
                  default: withCtx(() => [_hoisted_88]),
                  _: 1
                }, 8, ["class"]), createVNode(unref(RockButton), {
                  type: "button",
                  class: normalizeClass(unnasignedProjectsSelected.value ? '' : 'btn-primary'),
                  onClick: selectAssignedProjects
                }, {
                  default: withCtx(() => [_hoisted_89]),
                  _: 1
                }, 8, ["class"])]), unnasignedProjectsSelected.value ? (openBlock(), createBlock(unref(Grid), {
                  key: 0,
                  definition: (_unref$projectsGridDe = unref(config).projectsGridDefinition) !== null && _unref$projectsGridDe !== void 0 ? _unref$projectsGridDe : undefined,
                  data: unassignedProjectsGridDataSource.value,
                  onSelectItem: onProjectEditClick,
                  keyField: "id",
                  itemTerm: "Unassigned Project",
                  stickyHeader: ""
                }, {
                  default: withCtx(() => [createVNode(unref(TextColumn), {
                    name: "name",
                    field: "name",
                    title: "Name"
                  }), createVNode(unref(TextColumn), {
                    name: "partner",
                    field: "partner",
                    title: "Partner"
                  }), createVNode(unref(TextColumn), {
                    name: "location",
                    field: "location",
                    title: "Location"
                  }), createVNode(unref(TextColumn), {
                    name: "day",
                    field: "day",
                    title: "Day"
                  }), createVNode(unref(TextColumn), {
                    name: "time",
                    field: "time",
                    title: "Time",
                    width: "5%"
                  }), createVNode(unref(TextColumn), {
                    name: "suggestedOscName",
                    field: "suggestedOscName",
                    title: "Suggested OSC",
                    width: "12%"
                  }, {
                    format: withCtx(_ref9 => {
                      var row = _ref9.row;
                      return [row.suggestedOscId ? (openBlock(), createElementBlock("div", _hoisted_90, [createElementVNode("span", null, toDisplayString(row.suggestedOscName), 1), createElementVNode("div", _hoisted_91, [createVNode(unref(RockButton), {
                        type: "button",
                        class: "btn-primary btn-sm",
                        onClick: $event => onSuggestedOscAssignClick(row.id)
                      }, {
                        default: withCtx(() => [_hoisted_92]),
                        _: 2
                      }, 1032, ["onClick"])])])) : (openBlock(), createElementBlock("span", _hoisted_93, "No Optimal Assignee"))];
                    }),
                    _: 1
                  }), createVNode(unref(Column), {
                    name: "actions",
                    visiblePriority: "md",
                    width: "120"
                  }, {
                    format: withCtx(_ref10 => {
                      _ref10.row;
                      return [createElementVNode("div", _hoisted_94, [createVNode(unref(RockButton), {
                        type: "button",
                        class: "btn-warning btn-sm"
                      }, {
                        default: withCtx(() => [_hoisted_95]),
                        _: 1
                      })])];
                    }),
                    _: 1
                  })]),
                  _: 1
                }, 8, ["definition", "data"])) : createCommentVNode("v-if", true), !unnasignedProjectsSelected.value ? (openBlock(), createBlock(unref(Grid), {
                  key: 1,
                  definition: (_unref$projectsGridDe2 = unref(config).projectsGridDefinition) !== null && _unref$projectsGridDe2 !== void 0 ? _unref$projectsGridDe2 : undefined,
                  data: assignedProjectsGridDataSource.value,
                  onSelectItem: onProjectEditClick,
                  keyField: "id",
                  itemTerm: "Assigned Project",
                  stickyHeader: ""
                }, {
                  default: withCtx(() => [createVNode(unref(TextColumn), {
                    name: "name",
                    field: "name",
                    title: "Name"
                  }), createVNode(unref(TextColumn), {
                    name: "partner",
                    field: "partner",
                    title: "Partner"
                  }), createVNode(unref(TextColumn), {
                    name: "location",
                    field: "location",
                    title: "Location"
                  }), createVNode(unref(TextColumn), {
                    name: "day",
                    field: "day",
                    title: "Day"
                  }), createVNode(unref(TextColumn), {
                    name: "time",
                    field: "time",
                    title: "Time",
                    width: "5%"
                  }), createVNode(unref(TextColumn), {
                    name: "selectedOscName",
                    field: "selectedOscName",
                    title: "OSC",
                    width: "12%"
                  }), createVNode(unref(Column), {
                    name: "actions",
                    visiblePriority: "md",
                    width: "120"
                  }, {
                    format: withCtx(_ref11 => {
                      _ref11.row;
                      return [createElementVNode("div", _hoisted_96, [createVNode(unref(RockButton), {
                        type: "button",
                        class: "btn-warning btn-sm"
                      }, {
                        default: withCtx(() => [_hoisted_97]),
                        _: 1
                      })])];
                    }),
                    _: 1
                  })]),
                  _: 1
                }, 8, ["definition", "data"])) : createCommentVNode("v-if", true), excludedOnSiteCoordinators.value && excludedOnSiteCoordinators.value.length ? (openBlock(), createElementBlock("div", _hoisted_98, [_hoisted_99, createElementVNode("div", _hoisted_100, [createElementVNode("ul", null, [(openBlock(true), createElementBlock(Fragment, null, renderList(excludedOnSiteCoordinators.value, excludedOsc => {
                  return openBlock(), createElementBlock("li", {
                    key: excludedOsc.id
                  }, [createElementVNode("span", null, [createTextVNode(toDisplayString("".concat(excludedOsc.name, " (Person ID: ").concat(excludedOsc.id, ")")) + " ", 1), createElementVNode("a", {
                    href: '/person/' + excludedOsc.id,
                    target: "_blank"
                  }, "[Go to Connect Profile]", 8, _hoisted_101)]), createElementVNode("ul", null, [excludedOsc.gender == unref(Gender).Unknown ? (openBlock(), createElementBlock("li", _hoisted_102, "Missing Gender")) : createCommentVNode("v-if", true), !excludedOsc.dayPreference ? (openBlock(), createElementBlock("li", _hoisted_103, "Missing Day Preferences")) : createCommentVNode("v-if", true), !excludedOsc.timePreference ? (openBlock(), createElementBlock("li", _hoisted_104, "Missing Time Preferences")) : createCommentVNode("v-if", true)])]);
                }), 128))])])])) : createCommentVNode("v-if", true)]))])) : (openBlock(), createElementBlock("div", _hoisted_105, " Initial block configuration is not set properly. Please set all the required block basic settings and then reload the page. ")), createElementVNode("div", null, [createCommentVNode(" Modal Dialog for Suggested OSC assign "), createVNode(unref(Modal), {
                  onCloseModal: closeSuggestedOscAssignModal,
                  saveText: isSuggestedOscAssignModalSaving.value ? 'Confirming' : 'Confirm',
                  onSave: onSeggestedOscAssignSaveClick,
                  modelValue: isSuggestedOscAssignModalVisible.value,
                  title: "Confirm Assignment",
                  isSaveButtonDisabled: isSuggestedOscAssignModalSaving.value
                }, {
                  default: withCtx(() => {
                    var _suggestedOscModalPro, _suggestedOscModalPro2;
                    return [createElementVNode("div", null, [errorMessage.value ? (openBlock(), createBlock(unref(NotificationBox), {
                      key: 0,
                      alertType: "danger"
                    }, {
                      default: withCtx(() => [createTextVNode(toDisplayString(errorMessage.value), 1)]),
                      _: 1
                    })) : createCommentVNode("v-if", true), oscAssignWarnings.value && oscAssignWarnings.value.length ? (openBlock(), createBlock(unref(NotificationBox), {
                      key: 1,
                      alertType: "warning"
                    }, {
                      default: withCtx(() => [(openBlock(true), createElementBlock(Fragment, null, renderList(oscAssignWarnings.value, (warning, index) => {
                        return openBlock(), createElementBlock("p", {
                          key: index
                        }, toDisplayString(warning), 1);
                      }), 128))]),
                      _: 1
                    })) : createCommentVNode("v-if", true), _hoisted_106, createElementVNode("h2", _hoisted_107, toDisplayString((_suggestedOscModalPro = suggestedOscModalProjectSelected.value) === null || _suggestedOscModalPro === void 0 ? void 0 : _suggestedOscModalPro.suggestedOscName), 1), _hoisted_108, createElementVNode("h2", _hoisted_109, toDisplayString((_suggestedOscModalPro2 = suggestedOscModalProjectSelected.value) === null || _suggestedOscModalPro2 === void 0 ? void 0 : _suggestedOscModalPro2.name) + "!", 1)])];
                  }),
                  _: 1
                }, 8, ["saveText", "modelValue", "isSaveButtonDisabled"]), createCommentVNode(" Modal Dialog for Regular OSC assign "), createVNode(unref(Modal), {
                  onCloseModal: closeRegularOscAssignModal,
                  saveText: isRegularOscAssignModalSaving.value ? 'Confirming' : 'Confirm',
                  onSave: onRegularOscAssignSaveClick,
                  modelValue: isRegularOscAssignModalVisible.value,
                  title: "Confirm Assignment",
                  isSaveButtonDisabled: isRegularOscAssignModalSaving.value
                }, {
                  default: withCtx(() => {
                    var _regularOscAssignModa, _regularOscAssignModa2, _selectedProject$valu51;
                    return [createElementVNode("div", null, [errorMessage.value ? (openBlock(), createBlock(unref(NotificationBox), {
                      key: 0,
                      alertType: "danger"
                    }, {
                      default: withCtx(() => [createTextVNode(toDisplayString(errorMessage.value), 1)]),
                      _: 1
                    })) : createCommentVNode("v-if", true), oscAssignWarnings.value && oscAssignWarnings.value.length ? (openBlock(), createBlock(unref(NotificationBox), {
                      key: 1,
                      alertType: "warning"
                    }, {
                      default: withCtx(() => [(openBlock(true), createElementBlock(Fragment, null, renderList(oscAssignWarnings.value, (warning, index) => {
                        return openBlock(), createElementBlock("p", {
                          key: index
                        }, toDisplayString(warning), 1);
                      }), 128))]),
                      _: 1
                    })) : createCommentVNode("v-if", true), _hoisted_110, createElementVNode("h2", _hoisted_111, toDisplayString("".concat((_regularOscAssignModa = regularOscAssignModalPersonSelected.value) === null || _regularOscAssignModa === void 0 ? void 0 : _regularOscAssignModa.name, " (").concat((_regularOscAssignModa2 = regularOscAssignModalPersonSelected.value) === null || _regularOscAssignModa2 === void 0 ? void 0 : _regularOscAssignModa2.formattedMatchPercentage, ")")), 1), _hoisted_112, createElementVNode("h2", _hoisted_113, toDisplayString((_selectedProject$valu51 = selectedProject.value) === null || _selectedProject$valu51 === void 0 ? void 0 : _selectedProject$valu51.name) + "!", 1)])];
                  }),
                  _: 1
                }, 8, ["saveText", "modelValue", "isSaveButtonDisabled"]), createCommentVNode(" Modal Dialog for OSC assigned projects details "), createVNode(unref(Modal), {
                  onCloseModal: closeOscAssignedProjectsModal,
                  cancelText: 'Close',
                  modelValue: isOscAssignedProjectsModalVisible.value,
                  title: "Assigned Projects"
                }, {
                  default: withCtx(() => [createElementVNode("div", null, [createElementVNode("div", _hoisted_114, [_hoisted_115, createElementVNode("div", _hoisted_116, [_hoisted_117, (openBlock(true), createElementBlock(Fragment, null, renderList(selectedOscProjects.value, selectedOscProject => {
                    var _selectedOscProject$l;
                    return openBlock(), createElementBlock("div", {
                      class: "grid-row grid-row-odd",
                      key: selectedOscProject.id
                    }, [createElementVNode("div", _hoisted_118, toDisplayString(selectedOscProject.name), 1), createElementVNode("div", _hoisted_119, [createElementVNode("span", {
                      class: normalizeClass(getGenderClassForOscAssignedProjects(selectedOscProject.gender))
                    }, toDisplayString(selectedOscProject.gender != unref(Gender).Unknown ? selectedOscProject.genderString : 'Not Specified'), 3)]), createElementVNode("div", _hoisted_120, [createElementVNode("span", {
                      class: normalizeClass(getLocationClassForOscAssignedProjects(selectedOscProject.location))
                    }, toDisplayString((_selectedOscProject$l = selectedOscProject.location) !== null && _selectedOscProject$l !== void 0 ? _selectedOscProject$l : 'Not Provided'), 3)]), createElementVNode("div", _hoisted_121, [createElementVNode("div", _hoisted_122, [createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Monday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "M", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Tuesday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "T", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Wednesday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "W", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Thursday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "T", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Friday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "F", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Saturday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "S", 2), createElementVNode("span", {
                      class: normalizeClass(getDayMatchClassForOscAssignedProjects('Sunday', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.day))
                    }, "S", 2)])]), createElementVNode("div", _hoisted_123, [createElementVNode("div", _hoisted_124, [createElementVNode("span", {
                      innerHTML: getTimeOfDayIcon('Morning'),
                      class: normalizeClass(getTimeMatchClassForOscAssignedProjects('Morning', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.timeOfDay)),
                      "data-toggle": "tooltip",
                      title: "Morning Session: 8am - 12pm"
                    }, null, 10, _hoisted_125), createElementVNode("span", {
                      innerHTML: getTimeOfDayIcon('Afternoon'),
                      class: normalizeClass(getTimeMatchClassForOscAssignedProjects('Afternoon', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.timeOfDay)),
                      "data-toggle": "tooltip",
                      title: "Afternoon Session: 12pm - 4pm"
                    }, null, 10, _hoisted_126), createElementVNode("span", {
                      innerHTML: getTimeOfDayIcon('Evening'),
                      class: normalizeClass(getTimeMatchClassForOscAssignedProjects('Evening', selectedOscProject === null || selectedOscProject === void 0 ? void 0 : selectedOscProject.timeOfDay)),
                      "data-toggle": "tooltip",
                      title: "Evening Session: 4pm - 9pm"
                    }, null, 10, _hoisted_127)])])]);
                  }), 128)), _hoisted_128])])])]),
                  _: 1
                }, 8, ["modelValue"])])];
              }),
              _: 1
            });
          };
        }
      }));

      function styleInject(css, ref) {
        if (ref === void 0) ref = {};
        var insertAt = ref.insertAt;
        if (!css || typeof document === 'undefined') {
          return;
        }
        var head = document.head || document.getElementsByTagName('head')[0];
        var style = document.createElement('style');
        style.type = 'text/css';
        if (insertAt === 'top') {
          if (head.firstChild) {
            head.insertBefore(style, head.firstChild);
          } else {
            head.appendChild(style);
          }
        } else {
          head.appendChild(style);
        }
        if (style.styleSheet) {
          style.styleSheet.cssText = css;
        } else {
          style.appendChild(document.createTextNode(css));
        }
      }

      var css_248z = ".match-item[data-v-5389bf33]{align-items:center;background:none;border:2px solid #d3d3d3;border-radius:16px;color:#d3d3d3;cursor:default;line-height:20px;outline:none;padding:0 8px;text-decoration:none;vertical-align:middle;white-space:nowrap}.match-item.match[data-v-5389bf33]{background:green;border-color:green;color:#fff}.day-time-container[data-v-5389bf33]{border:2px solid #d3d3d3;border-radius:12px;color:#d3d3d3;cursor:default;height:24px;line-height:20px;margin:3px;text-align:center;width:24px}.day-time-container.match[data-v-5389bf33]{background:#90ee90;border-color:#90ee90;color:green}.day-time-container.exact-match[data-v-5389bf33]{background:green;border-color:green;color:#fff}.day-time-container.time[data-v-5389bf33]{line-height:inherit}";
      styleInject(css_248z);

      script.__scopeId = "data-v-5389bf33";
      script.__file = "src/team_passion/OscMatching/matchingTool.obs";

    })
  };
}));
//# sourceMappingURL=matchingTool.obs.js.map
