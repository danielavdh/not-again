//import "@hotwired/turbo-rails";
//Turbo.session.drive = false;

async function loadModules() {
	try {
		/* wait for window.load */
		const windowLoadPromise = new Promise(resolve => {
		    if (document.readyState === 'complete') {
		        resolve();
		    } else {
				window.addEventListener('load', function() {
				    resolve();
				});
		    }
		});
		/* wait for DOM loaded
		 * document.readyState can only be "loading, interactive or complete"!! */		
		const domReadyPromise = new Promise(resolve => {
		    if (document.readyState === 'loading') {
		        document.addEventListener('DOMContentLoaded', resolve);
		    } else {
		        resolve();
		    }
		});
		/* make sure modules are loaded in right order and no race conditions arise
		 * and only call using elements after DOM loaded */
		/* Promise.all awaits 2 promises [(async(){}), windowLoadPromise)]
		 * (async(){}) returns vdh, windowLoadPromise returns undefined
		 * const [vdh] is destructuring assignment */				
		const [vdh] = await Promise.all([
			(async () => {
	    		await Promise.all([
					/* 1: any modules that are required first */
	    		    //import("frontend/jquery_ui_ml"),
	    		    //import("frontend/jquery.event.move")
	    		]);
        		
				/* 2: any modules that depend on the ones loaded first */
	    		//await import("frontend/jquery.imageLens");
				/* 3: import main APP module, exporting default APP */
	    		const { default: vdh } = await import('scripts');
				/* 4: wait for dom ready resolution before intializing code */
				await domReadyPromise;
//				await vdh.debug();
				/* run initialization code (old dom ready code) */
				await vdh.initBackend();
				await vdh.initAccounts();
//				await vdh.initListeners();
//				await vdh.initPreview();
				/* run any other initialization code */
				//await APP.initOTHERCODE1();
				//await APP.initOTHERCODE2();
				/* return APP */
				return vdh;
			})(),
			/* run window.load code */
			windowLoadPromise
		]);
		/* this is good for code that needs to be called after window.load
		 * or when all the Promises are fulfilled = all the modules are loaded */
//	  	ensurePageHeight();

	} catch (error) {
	    console.error("Failed to initialize application:", error);
	}	
};

loadModules();



