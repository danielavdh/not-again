import { debounce, isPhoneWidth, isDesktopWidth } from "scripts/utils";

let TomSelect = null;

/**
 * Generalized TomSelect Component
 * 
 * Usage: Add data attributes to select elements:
 * 
 * Basic usage (static options):
 *   <select data-tomselect>
 *     <option value="1">Option 1</option>
 *   </select>
 * 
 * With AJAX search:
 *   <select data-tomselect 
 *           data-tomselect-url="/api/search" 
 *           data-tomselect-param="query">
 *   </select>
 * 
 * Custom placeholder:
 *   <select data-tomselect 
 *           data-tomselect-placeholder="Select an option...">
 *   </select>
 * 
 * With change callback:
 *   <select data-tomselect 
 *           data-tomselect-change="myFunction">
 *   </select>
 *   
 * Additional options:
 *   data-tomselect-create="true" - Allow creating new options
 *   data-tomselect-max-options="50" - Max options to display
 *   data-tomselect-multiple="true" - Multiple selection
 *   data-tomselect-debounce="300" - Debounce delay for AJAX (ms)
 */

const TomSelectHelper = {
    instances: new Map(),
    
    /**
     * Load TomSelect library dynamically
     */
    async loadLibrary() {
        if (TomSelect) return TomSelect;
        
        try {
            const module = await import('tom-select');
            TomSelect = module.default || module.TomSelect || module;
            return TomSelect;
        } catch (error) {
            console.error("Failed to load TomSelect:", error);
            return null;
        }
    },
    
    /**
     * Initialize all TomSelect elements on the page
     */
    async init() {
        await this.loadLibrary();
        if (!TomSelect) return;
        
        // Initialize all elements with data-tomselect attribute
        const selects = document.querySelectorAll('[data-tomselect]:not([data-tomselect-initialized])');
        selects.forEach(select => this.initializeSelect(select));
    },
    
    /**
     * Initialize a single select element with TomSelect
     * @param {HTMLSelectElement} select - The select element to initialize
     * @param {Object} customOptions - Optional custom options to override defaults
     */
    initializeSelect(select, customOptions = {}) {
        if (!TomSelect || !select || select.tomselect || select.dataset.tomselectInitialized) {
            return;
        }
        
        // Get configuration from data attributes
        const config = this.getConfigFromDataAttributes(select);
        
        // Merge with custom options
        const options = { ...config, ...customOptions };
        
        try {
            // Create TomSelect instance
            const instance = new TomSelect(select, options);
            
            // Store instance for later access
            this.instances.set(select, instance);
            
            // Mark as initialized
            select.dataset.tomselectInitialized = 'true';
            
            // Setup change callback if specified
            if (select.dataset.tomselectChange) {
                const callbackName = select.dataset.tomselectChange;
                if (window[callbackName] && typeof window[callbackName] === 'function') {
                    instance.on('change', (value) => {
                        window[callbackName](value, select, instance);
                    });
                }
            }
            
            return instance;
        } catch (error) {
            console.error("Failed to initialize TomSelect on element:", select, error);
            return null;
        }
    },
    
    /**
     * Get TomSelect configuration from data attributes
     * @param {HTMLSelectElement} select
     * @returns {Object} Configuration object for TomSelect
     */
    getConfigFromDataAttributes(select) {
        const config = {
			highlight: false,
            placeholder: select.dataset.tomselectPlaceholder || 'Select...',
            allowEmptyOption: true,
            create: select.dataset.tomselectCreate === 'true',
            maxOptions: parseInt(select.dataset.tomselectMaxOptions) || 100,
            sortField: {
                field: "text",
                direction: "asc"
            }
        };
        
        // Handle multiple selection
        if (select.dataset.tomselectMultiple === 'true') {
            config.mode = 'multi';
        }
        
        // Handle AJAX search
        const url = select.dataset.tomselectUrl;
        if (url) {
            const paramName = select.dataset.tomselectParam || 'q';
            const debounceDelay = parseInt(select.dataset.tomselectDebounce) || 300;
            
            config.load = debounce(function(query, callback) {
                if (!query.length) return callback();
                
                const searchUrl = new URL(url, window.location.origin);
                searchUrl.searchParams.set(paramName, query);
                
                fetch(searchUrl, {
                    method: 'GET',
                    headers: {
                        'Accept': 'application/json',
                        'X-Requested-With': 'XMLHttpRequest'
                    }
                })
                .then(response => response.json())
                .then(data => {
                    // Expect data to be array of {value, text} or {id, name}
                    const options = data.map(item => ({
                        value: item.value || item.id,
                        text: item.text || item.name || item.label
                    }));
                    callback(options);
                })
                .catch(error => {
                    console.error('TomSelect AJAX error:', error);
                    callback();
                });
            }, debounceDelay);
            
            // Disable initial loading of all options for AJAX mode
            config.preload = false;
        }
        
        if (select.classList.contains('posting-account')) {
            config.render = {
                item: (data, escape) => {
                    // Bands come from --is-phone / --is-desktop in
                    // shared/_config.scss, so the breakpoints are not repeated here.
                    const max = isDesktopWidth() ? 40 : isPhoneWidth() ? 18 : 22;
                    const text = data.text || '';
                    const label = text.length > max ? text.slice(0, max) + '…' : text;
                    return `<div class="item">${escape(label)}</div>`;
                }
            };
        }

        return config;
    },
    
    /**
     * Get TomSelect instance for a given select element
     * @param {HTMLSelectElement} select
     * @returns {Object|null} TomSelect instance
     */
    getInstance(select) {
        return select?.tomselect || this.instances.get(select) || null;
    },
    
    /**
     * Destroy TomSelect instance for a given select element
     * @param {HTMLSelectElement} select
     */
    destroyInstance(select) {
        const instance = this.getInstance(select);
        if (instance) {
            instance.destroy();
            this.instances.delete(select);
            delete select.dataset.tomselectInitialized;
        }
    },
    
    /**
     * Refresh/reinitialize all TomSelect instances
     */
    async refresh() {
        await this.init();
    },
    
    /**
     * Initialize TomSelect on a specific container (useful after dynamic content is added)
     * @param {HTMLElement} container - Container to search for selects
     */
    async initInContainer(container) {
        await this.loadLibrary();
        if (!TomSelect) return;
        
        const selects = container.querySelectorAll('[data-tomselect]:not([data-tomselect-initialized])');
        selects.forEach(select => this.initializeSelect(select));
    }
};

export default TomSelectHelper;
