window.__ModuleLoader__.load({
	id: "@local/dsh-model-select-plus",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		let react_jsx_runtime = require("react/jsx-runtime");
		let _deepseek_ai_dsh_client_ui_primitives = require("@deepseek-ai/dsh-client-ui-primitives");
		//#region styles
		/**
		 * Hand-written "CSS module" for the searchable model seat. Mirrors the
		 * official dsh-client-ui-model-selection stylesheet (same theme
		 * variables, same layout skeleton) with msp- class names, plus the
		 * search-box row, the dimmed provider prefix, and a persistent selected
		 * highlight. Injected once per page under a stable tag id; the module
		 * system's claimStyles() adopts the tag for HMR bookkeeping.
		 */
		const css = ".msp-root{min-width:0;position:relative}.msp-trigger{min-width:0;max-width:min(360px,45cqw);height:28px;color:var(--dsw-alias-label-secondary);cursor:pointer;background:0 0;border:none;border-radius:24px;outline:none;align-items:center;gap:4px;padding:0 4px 0 8px;font-size:13px;font-weight:500;line-height:20px;display:flex}.msp-trigger:hover:not(:disabled){background:var(--dsw-alias-interactive-bg-hover)}.msp-trigger:focus-visible{box-shadow:0 0 0 2px var(--dsw-alias-border-l3)}.msp-trigger:disabled{color:var(--dsw-alias-label-dimmed);cursor:default}.msp-triggerLabel{text-overflow:ellipsis;white-space:nowrap;min-width:0;overflow:hidden}.msp-triggerEffort{color:var(--dsw-alias-label-caption);flex:none}.msp-chevron{color:var(--dsw-alias-label-caption);flex:none;transition:transform .12s}.msp-chevronOpen{transform:rotate(180deg)}.msp-menu{z-index:20;border:1px solid var(--dsw-alias-border-inverted);background:var(--dsw-specific-menu);width:max-content;min-width:min(280px,100vw - 32px);max-width:min(420px,100vw - 32px);max-height:min(400px,100vh - 96px);box-shadow:var(--dsw-shadow-lv3);color:var(--dsw-alias-label-primary);--dsh-scrollbar-thumb:var(--dsw-alias-scrollbar-bg-l2);--dsh-scrollbar-thumb-hover:var(--dsw-alias-scrollbar-hover-l2);border-radius:12px;flex-direction:column;padding:4px;display:flex;position:absolute;bottom:calc(100% + 8px);right:0;overflow:hidden}.msp-search{border-bottom:1px solid var(--dsw-alias-border-l2);flex:none;padding:2px 4px 8px;margin-bottom:4px}.msp-input{width:100%;height:28px;box-sizing:border-box;background:var(--dsw-alias-interactive-bg-hover);border:1px solid transparent;border-radius:8px;color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;line-height:20px;outline:none;padding:0 8px}.msp-input:focus{border-color:var(--dsw-alias-border-l3);background:0 0}.msp-input::placeholder{color:var(--dsw-alias-label-caption)}.msp-status,.msp-empty{color:var(--dsw-alias-label-tertiary);padding:10px;font-size:13px;line-height:20px}.msp-error,.msp-warning{background:var(--dsw-alias-interactive-bg-hover-danger);color:var(--dsw-alias-state-error-primary);border-radius:8px;justify-content:space-between;align-items:flex-start;gap:8px;margin-bottom:4px;padding:7px 8px;font-size:12px;line-height:18px;display:flex}.msp-warning{background:var(--dsw-alias-bg-module-platform);color:var(--dsw-alias-state-warn-label)}.msp-retry{color:inherit;font:inherit;cursor:pointer;background:0 0;border:none;flex:none;padding:0;font-weight:600}.msp-groups{min-height:0;overflow-y:auto}.msp-option{box-sizing:border-box;width:auto;min-width:100%;min-height:38px;color:inherit;text-align:left;cursor:pointer;background:0 0;border:none;border-radius:10px;outline:none;align-items:center;gap:8px;padding:6px 8px;display:flex}.msp-option:hover:not(:disabled),.msp-option:focus-visible{background:var(--dsw-alias-interactive-bg-hover)}.msp-option.msp-selected{background:var(--dsw-alias-interactive-bg-hover)}.msp-option:disabled{color:var(--dsw-alias-label-dimmed);cursor:default}.msp-optionCopy{flex-direction:column;flex:1;min-width:0;display:flex}.msp-modelName{color:inherit;text-overflow:ellipsis;white-space:nowrap;font-size:14px;font-weight:500;line-height:20px;overflow:hidden}.msp-provider{color:var(--dsw-alias-label-tertiary)}.msp-description{color:var(--dsw-alias-label-tertiary);text-overflow:ellipsis;white-space:nowrap;font-size:12px;line-height:18px;overflow:hidden}.msp-check{color:var(--dsw-alias-label-primary);flex:0 0 18px;place-items:center;display:grid}.msp-cell{box-sizing:border-box;width:auto;min-width:100%;height:40px;color:var(--dsw-alias-label-primary);cursor:pointer;text-align:left;background:0 0;border:none;border-radius:10px;align-items:center;gap:8px;padding:0 10px;font-size:14px;line-height:22px;display:flex}.msp-cell:hover{background:var(--dsw-alias-interactive-bg-hover)}.msp-cellLabel{white-space:nowrap;flex:none}.msp-cellValue{text-overflow:ellipsis;white-space:nowrap;text-align:right;min-width:0;color:var(--dsw-alias-label-tertiary);flex:auto;overflow:hidden}.msp-cellChevron{color:var(--dsw-alias-label-tertiary);flex:none}";
		const tagId = "@local/dsh-model-select-plus/ModelSelectPlus.module.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "@local/dsh-model-select-plus";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		var ModelSelectPlus_module_css_default = {
			"cell": "msp-cell",
			"cellChevron": "msp-cellChevron",
			"cellLabel": "msp-cellLabel",
			"cellValue": "msp-cellValue",
			"check": "msp-check",
			"chevron": "msp-chevron",
			"chevronOpen": "msp-chevronOpen",
			"description": "msp-description",
			"empty": "msp-empty",
			"error": "msp-error",
			"groups": "msp-groups",
			"input": "msp-input",
			"menu": "msp-menu",
			"modelName": "msp-modelName",
			"option": "msp-option",
			"optionCopy": "msp-optionCopy",
			"provider": "msp-provider",
			"retry": "msp-retry",
			"root": "msp-root",
			"search": "msp-search",
			"selected": "msp-selected",
			"status": "msp-status",
			"trigger": "msp-trigger",
			"triggerEffort": "msp-triggerEffort",
			"triggerLabel": "msp-triggerLabel",
			"warning": "msp-warning"
		};
		//#endregion
		//#region lib/classnames
		/** Minimal clsx stand-in: the vendor seed table has no clsx module, and this artifact vendors its only needed behavior. */
		function cx() {
			let out = "";
			for (const part of arguments) if (part) out += out === "" ? part : ` ${part}`;
			return out;
		}
		//#endregion
		//#region lib/ModelSelectPlus.js
		/**
		 * ModelSelectPlus: replaces the composer's `conversation.input.model` seat
		 * with a searchable, provider-prefixed selector. Structure and behavior
		 * mirror the official ModelSelect (two-level Model/Effort menu, shared
		 * per-session ModelDirectory, failure rows with retry, keyboard focus
		 * cycling, click-outside close, toast on rejected selection); the model
		 * pane gains an auto-focused search box (case-insensitive substring over
		 * provider name/id and model name/id) and every row reads
		 * `Provider / model` with the description as secondary copy. The official
		 * occupant stays mounted but shadowed (single seat, later registration
		 * wins), so its ModelDirectoryResolver and /model command keep serving.
		 */
		function ModelSelectPlus({ locked, available, directory, load, select, t }) {
			const state = (0, react.useSyncExternalStore)((fn) => directory.subscribe(fn), () => directory.getSnapshot());
			const [open, setOpen] = (0, react.useState)(false);
			const [pane, setPane] = (0, react.useState)("root");
			const [query, setQuery] = (0, react.useState)("");
			const lastActionRef = (0, react.useRef)("load");
			const [toast, setToast] = (0, react.useState)(null);
			const toastSeq = (0, react.useRef)(0);
			const rootRef = (0, react.useRef)(null);
			const triggerRef = (0, react.useRef)(null);
			const searchRef = (0, react.useRef)(null);
			const itemRefs = (0, react.useRef)([]);
			const id = (0, react.useId)();
			const choices = (0, react.useMemo)(() => state.groups.flatMap((group) => group.models.map((model) => ({
				group,
				model,
				selection: {
					provider: group.id,
					model: model.id,
					...model.reasoning?.defaultEffort === void 0 ? {} : { reasoningEffort: model.reasoning.defaultEffort }
				}
			}))), [state.groups]);
			const currentChoice = state.current === null ? void 0 : choices.find((c) => c.selection.provider === state.current?.provider && c.selection.model === state.current.model);
			const reasoning = currentChoice?.model.reasoning;
			const effectiveEffort = state.current?.reasoningEffort ?? reasoning?.defaultEffort;
			const effortLabel = reasoning === void 0 ? void 0 : effectiveEffort === void 0 ? t("effort.providerDefault") : reasoning.efforts.find((level) => level.id === effectiveEffort)?.name ?? effectiveEffort;
			const effortChoices = (0, react.useMemo)(() => reasoning === void 0 ? [] : [...reasoning.defaultEffort === void 0 ? [{
				key: "provider-default",
				effort: void 0,
				label: t("effort.providerDefault")
			}] : [], ...reasoning.efforts.map((effort) => ({
				key: `effort:${effort.id}`,
				effort: effort.id,
				label: effort.name,
				...effort.description === void 0 ? {} : { description: effort.description }
			}))], [reasoning, t]);
			const needle = query.trim().toLowerCase();
			const visibleGroups = (0, react.useMemo)(() => needle === "" ? state.groups : state.groups.map((group) => ({
				...group,
				models: group.models.filter((model) => group.name.toLowerCase().includes(needle) || group.id.toLowerCase().includes(needle) || model.name.toLowerCase().includes(needle) || model.id.toLowerCase().includes(needle))
			})).filter((group) => group.models.length > 0), [state.groups, needle]);
			const visibleCount = visibleGroups.reduce((count, group) => count + group.models.length, 0);
			const busy = state.status === "selecting";
			const reload = () => {
				lastActionRef.current = "load";
				load();
			};
			(0, react.useEffect)(() => {
				if (available) {
					lastActionRef.current = "load";
					load();
				}
			}, [available, load]);
			(0, react.useEffect)(() => {
				if (!open) return;
				const closeOutside = (event) => {
					if (!rootRef.current?.contains(event.target)) setOpen(false);
				};
				document.addEventListener("mousedown", closeOutside);
				return () => {
					document.removeEventListener("mousedown", closeOutside);
				};
			}, [open]);
			(0, react.useEffect)(() => {
				/* Pane-switch focus recovery: the drilled-from cell unmounts and
				 * strands focus on body (a native-blur-less removal the official
				 * selector never recovers from). Deterministically seat focus —
				 * the search box in the model pane, otherwise the first item. */
				if (!open) return;
				const active = document.activeElement;
				if (active instanceof Node && rootRef.current?.contains(active)) return;
				if (pane === "model") searchRef.current?.focus();
				else itemRefs.current.filter((item) => item !== null)[0]?.focus();
			}, [open, pane]);
			if (!available) return null;
			const show = () => {
				setPane("root");
				setQuery("");
				setOpen(true);
				reload();
			};
			const close = (restoreFocus = false) => {
				setOpen(false);
				setPane("root");
				if (restoreFocus) queueMicrotask(() => {
					triggerRef.current?.focus();
				});
			};
			const moveFocus = (offset) => {
				const items = itemRefs.current.filter((item) => item !== null);
				if (items.length === 0) return;
				const active = items.findIndex((item) => item === document.activeElement);
				items[(Math.max(active, 0) + offset + items.length) % items.length]?.focus();
			};
			const onRootKeyDown = (event) => {
				if (event.key === "Escape" && open) {
					event.preventDefault();
					if (pane === "model" && query !== "") {
						setQuery("");
						searchRef.current?.focus();
					} else if (pane !== "root") setPane("root");
					else close(true);
					return;
				}
				if (!open) return;
				if (event.key === "ArrowDown" || event.key === "ArrowUp") {
					event.preventDefault();
					moveFocus(event.key === "ArrowDown" ? 1 : -1);
				}
			};
			const onBlur = (event) => {
				if (event.relatedTarget instanceof Node && rootRef.current?.contains(event.relatedTarget)) return;
				close();
			};
			const settleSelection = (accepted) => {
				if (accepted) {
					if (rootRef.current !== null) close(true);
					return;
				}
				const message = directory.getSnapshot().error;
				if (message !== null) {
					toastSeq.current += 1;
					setToast({
						seq: toastSeq.current,
						text: t("error.action", { message })
					});
				}
			};
			const choose = (selection) => {
				if (state.current?.provider === selection.provider && state.current.model === selection.model) {
					close(true);
					return;
				}
				lastActionRef.current = "select";
				select(selection).then(settleSelection);
			};
			const chooseEffort = (effort) => {
				if (state.current === null) return;
				if (effectiveEffort === effort) {
					close(true);
					return;
				}
				const selection = {
					provider: state.current.provider,
					model: state.current.model,
					...effort === void 0 ? {} : { reasoningEffort: effort }
				};
				lastActionRef.current = "select";
				select(selection).then(settleSelection);
			};
			const currentText = currentChoice === void 0 ? void 0 : `${currentChoice.group.name} / ${currentChoice.model.name}`;
			const triggerText = currentText ?? t("trigger.fallback");
			const triggerLabel = effortLabel === void 0 ? triggerText : `${triggerText} · ${effortLabel}`;
			const triggerAria = currentChoice === void 0 ? t("trigger.fallback") : effortLabel === void 0 ? t("trigger.aria", { model: triggerText }) : t("trigger.ariaEffort", {
				model: triggerText,
				effort: effortLabel
			});
			itemRefs.current = [];
			let itemIndex = 0;
			const itemRef = () => {
				const at = itemIndex++;
				return (node) => {
					itemRefs.current[at] = node;
				};
			};
			const searchItemRef = () => {
				const at = itemIndex++;
				return (node) => {
					itemRefs.current[at] = node;
					searchRef.current = node;
				};
			};
			return (0, react_jsx_runtime.jsxs)("div", {
				ref: rootRef,
				className: ModelSelectPlus_module_css_default.root,
				onKeyDown: onRootKeyDown,
				onBlur,
				children: [
					(0, react_jsx_runtime.jsxs)("button", {
						ref: triggerRef,
						type: "button",
						className: ModelSelectPlus_module_css_default.trigger,
						"aria-label": triggerAria,
						"aria-haspopup": "menu",
						"aria-expanded": open,
						"aria-controls": open ? `${id}-menu` : void 0,
						title: triggerLabel,
						disabled: locked,
						onClick: () => {
							if (open) close();
							else show();
						},
						children: [
							(0, react_jsx_runtime.jsx)("span", {
								className: ModelSelectPlus_module_css_default.triggerLabel,
								children: triggerText
							}),
							effortLabel !== void 0 && (0, react_jsx_runtime.jsx)("span", {
								className: ModelSelectPlus_module_css_default.triggerEffort,
								children: effortLabel
							}),
							(0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconChevronDownOutline14, { className: cx(ModelSelectPlus_module_css_default.chevron, open && ModelSelectPlus_module_css_default.chevronOpen) })
						]
					}),
					open && (0, react_jsx_runtime.jsxs)("div", {
						id: `${id}-menu`,
						className: ModelSelectPlus_module_css_default.menu,
						role: "menu",
						"aria-label": t("menu.aria"),
						"aria-busy": state.status === "loading" || busy,
						children: [
							pane === "root" && (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [(0, react_jsx_runtime.jsxs)("button", {
								ref: itemRef(),
								type: "button",
								role: "menuitem",
								className: ModelSelectPlus_module_css_default.cell,
								onClick: () => {
									setPane("model");
								},
								children: [
									(0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.cellLabel,
										children: t("menu.model")
									}),
									(0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.cellValue,
										children: triggerText
									}),
									(0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconChevronRightOutline14, { className: ModelSelectPlus_module_css_default.cellChevron })
								]
							}), reasoning !== void 0 && (0, react_jsx_runtime.jsxs)("button", {
								ref: itemRef(),
								type: "button",
								role: "menuitem",
								className: ModelSelectPlus_module_css_default.cell,
								onClick: () => {
									setPane("effort");
								},
								children: [
									(0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.cellLabel,
										children: t("menu.effort")
									}),
									(0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.cellValue,
										children: effortLabel
									}),
									(0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconChevronRightOutline14, { className: ModelSelectPlus_module_css_default.cellChevron })
								]
							})] }),
							pane === "model" && (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [
								(0, react_jsx_runtime.jsx)("div", {
									className: ModelSelectPlus_module_css_default.search,
									children: (0, react_jsx_runtime.jsx)("input", {
										ref: searchItemRef(),
										type: "text",
										"aria-label": t("search.placeholder"),
										className: ModelSelectPlus_module_css_default.input,
										placeholder: t("search.placeholder"),
										spellCheck: false,
										value: query,
										onChange: (event) => {
											setQuery(event.target.value);
										}
									})
								}),
								state.status === "loading" && (0, react_jsx_runtime.jsx)("div", {
									className: ModelSelectPlus_module_css_default.status,
									children: t("status.loading")
								}),
								state.error !== null && lastActionRef.current === "load" && (0, react_jsx_runtime.jsxs)("div", {
									className: ModelSelectPlus_module_css_default.error,
									children: [(0, react_jsx_runtime.jsx)("span", { children: t("error.action", { message: state.error }) }), (0, react_jsx_runtime.jsx)("button", {
										type: "button",
										className: ModelSelectPlus_module_css_default.retry,
										onClick: reload,
										children: t("retry")
									})]
								}),
								state.failures.map((failure) => (0, react_jsx_runtime.jsxs)("div", {
									className: ModelSelectPlus_module_css_default.warning,
									children: [(0, react_jsx_runtime.jsx)("span", { children: t("warning.groupLoad", {
										name: failure.name,
										message: failure.message
									}) }), (0, react_jsx_runtime.jsx)("button", {
										type: "button",
										className: ModelSelectPlus_module_css_default.retry,
										onClick: reload,
										children: t("retry")
									})]
								}, failure.id)),
								(0, react_jsx_runtime.jsx)("div", {
									className: cx(ModelSelectPlus_module_css_default.groups, "scrollable"),
									children: visibleGroups.flatMap((group) => group.models.map((model) => {
										const selected = state.current?.provider === group.id && state.current.model === model.id;
										return (0, react_jsx_runtime.jsxs)("button", {
											ref: itemRef(),
											type: "button",
											role: "menuitemradio",
											"aria-checked": selected,
											className: cx(ModelSelectPlus_module_css_default.option, selected && ModelSelectPlus_module_css_default.selected),
											title: `${group.name} / ${model.name}`,
											disabled: busy,
											onClick: () => {
												choose({
													provider: group.id,
													model: model.id
												});
											},
											children: [(0, react_jsx_runtime.jsxs)("span", {
												className: ModelSelectPlus_module_css_default.optionCopy,
												children: [(0, react_jsx_runtime.jsxs)("span", {
													className: ModelSelectPlus_module_css_default.modelName,
													children: [(0, react_jsx_runtime.jsx)("span", {
														className: ModelSelectPlus_module_css_default.provider,
														children: `${group.name} / `
													}), model.name]
												}), model.description !== void 0 && (0, react_jsx_runtime.jsx)("span", {
													className: ModelSelectPlus_module_css_default.description,
													children: model.description
												})]
											}), (0, react_jsx_runtime.jsx)("span", {
												className: ModelSelectPlus_module_css_default.check,
												children: selected ? (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconCheckOutline16, {}) : null
											})]
										}, `${group.id}/${model.id}`);
									}))
								}),
								state.status === "ready" && choices.length === 0 && needle === "" && (0, react_jsx_runtime.jsx)("div", {
									className: ModelSelectPlus_module_css_default.empty,
									children: t("empty.models")
								}),
								needle !== "" && visibleCount === 0 && (0, react_jsx_runtime.jsx)("div", {
									className: ModelSelectPlus_module_css_default.empty,
									children: t("search.noMatches")
								})
							] }),
							pane === "effort" && (0, react_jsx_runtime.jsxs)(react_jsx_runtime.Fragment, { children: [state.error !== null && lastActionRef.current === "load" && (0, react_jsx_runtime.jsxs)("div", {
								className: ModelSelectPlus_module_css_default.error,
								children: [(0, react_jsx_runtime.jsx)("span", { children: t("error.action", { message: state.error }) }), (0, react_jsx_runtime.jsx)("button", {
									type: "button",
									className: ModelSelectPlus_module_css_default.retry,
									onClick: reload,
									children: t("action.reload")
								})]
							}), effortChoices.length === 0 ? (0, react_jsx_runtime.jsx)("div", {
								className: ModelSelectPlus_module_css_default.empty,
								children: t("empty.efforts")
							}) : effortChoices.map((level) => (0, react_jsx_runtime.jsxs)("button", {
								ref: itemRef(),
								type: "button",
								role: "menuitemradio",
								"aria-checked": effectiveEffort === level.effort,
								className: cx(ModelSelectPlus_module_css_default.option, effectiveEffort === level.effort && ModelSelectPlus_module_css_default.selected),
								disabled: busy,
								onClick: () => {
									chooseEffort(level.effort);
								},
								children: [(0, react_jsx_runtime.jsxs)("span", {
									className: ModelSelectPlus_module_css_default.optionCopy,
									children: [(0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.modelName,
										children: level.label
									}), level.description !== void 0 && (0, react_jsx_runtime.jsx)("span", {
										className: ModelSelectPlus_module_css_default.description,
										children: level.description
									})]
								}), (0, react_jsx_runtime.jsx)("span", {
									className: ModelSelectPlus_module_css_default.check,
									children: effectiveEffort === level.effort ? (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconCheckOutline16, {}) : null
								})]
							}, level.key))] })
						]
					}),
					toast !== null && (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.Toast, {
						text: toast.text,
						icon: (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconWarningOutline16, {}),
						anchor: rootRef.current?.closest("[data-composer-card]") ?? null,
						onDone: () => {
							setToast(null);
						}
					}, toast.seq)
				]
			});
		}
		//#endregion
		//#region lib/locales.js
		/** Dictionary namespace owned by this plugin (distinct from the official `model`). */
		const NS = "modelPlus";
		/** Simplified Chinese dictionary (the key-set source of truth). */
		const zh = {
			"trigger.fallback": "选择模型",
			"trigger.aria": "选择模型，当前 {model}",
			"trigger.ariaEffort": "选择模型，当前 {model}，推理等级 {effort}",
			"menu.aria": "模型与推理等级",
			"menu.model": "模型",
			"menu.effort": "推理等级",
			"effort.providerDefault": "Default",
			"status.loading": "正在刷新模型列表…",
			"error.action": "模型操作失败：{message}",
			"action.reload": "重新加载",
			"warning.groupLoad": "{name} 加载失败：{message}",
			"empty.models": "没有可用的模型。",
			"empty.efforts": "当前模型未提供推理等级。",
			"search.placeholder": "搜索模型或提供方…",
			"search.noMatches": "没有匹配的模型。"
		};
		/** English dictionary, checked complete against the zh key set. */
		const en = {
			"trigger.fallback": "Select model",
			"trigger.aria": "Select model, current {model}",
			"trigger.ariaEffort": "Select model, current {model}, reasoning effort {effort}",
			"menu.aria": "Model and reasoning effort",
			"menu.model": "Model",
			"menu.effort": "Effort",
			"effort.providerDefault": "Default",
			"status.loading": "Refreshing model list…",
			"error.action": "Model operation failed: {message}",
			"action.reload": "Reload",
			"warning.groupLoad": "{name} failed to load: {message}",
			"empty.models": "No models available.",
			"empty.efforts": "This model provides no reasoning effort levels.",
			"search.placeholder": "Search models or providers…",
			"search.noMatches": "No matching models."
		};
		//#endregion
		//#region lib/index.client.js
		/** Required services: locale (dictionaries), the official directory resolver, session addressing, and the seat's slot registry. */
		const inject = [
			"locale",
			"modelDirectories",
			"sessions",
			"slots"
		];
		/**
		 * Client plugin body: register the `modelPlus` dictionaries, then take over
		 * the composer model seat over the OFFICIAL ModelDirectoryResolver — this
		 * plugin never re-registers the resolver and never touches the /model
		 * command; the official occupant stays mounted and is shadowed on the
		 * single seat (later registration wins).
		 * @param ctx - client root context.
		 */
		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, {
				zh,
				en
			}), "ui-model-select-plus: dictionaries");
			ctx.inject(["slots", "modelDirectories", "sessions"], (scope) => {
				const models = scope.modelDirectories;
				const sessions = scope.sessions;
				scope.slots.inject("conversation.input.model", () => scope.slots.register({
					name: "conversation.input.model",
					// Shadow the official occupant: single-slot election renders the
					// LOWEST priority, the official entry sits at effective 0, and a
					// same-priority registration throws instead of shadowing.
					priority: -1000,
					locale: NS,
					inject: (sessionId) => {
						const directory = models.directoryFor(sessionId);
						const available = sessions.subagentAddress(sessionId) === void 0;
						return {
							available,
							directory: directory.store,
							load: () => {
								if (available) directory.load().catch(() => {});
							},
							select: (selection) => available ? directory.select(selection).then(() => true, () => false) : Promise.resolve(false)
						};
					}
				}, ModelSelectPlus));
			});
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
