const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');
const violations=[];
function visit(dir,owner){
  for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    const file=path.join(dir,entry.name);
    if(entry.isDirectory()){visit(file,owner);continue;}
    if(!file.endsWith('.dart'))continue;
    const source=fs.readFileSync(file,'utf8');
    for(const match of source.matchAll(/(?:import|export)\s+['"]([^'"]+)['"]/g)){
      const target=match[1];
      for(const app of ['core','vpn','files']){
        if(target.startsWith('package:easyprivacy_'+app+'/')&&app!==owner)violations.push(path.relative(root,file)+': '+target);
      }
      if(target.includes('/apps/')||target.startsWith('../apps/'))violations.push(path.relative(root,file)+': '+target);
    }
  }
}
for(const app of ['core','vpn','files'])visit(path.join(root,'apps',app,'lib'),app);
for(const entry of fs.readdirSync(path.join(root,'packages')))visit(path.join(root,'packages',entry,'lib'),null);
const products=new Set(),androidIds=new Set();
for(const app of ['core','vpn','files']){
  const runner=fs.readFileSync(path.join(root,'apps',app,'windows/runner/Runner.rc'),'utf8');
  const product=runner.match(/VALUE\s+"ProductName",\s+"([^"]+)"/)?.[1];
  if(!product||products.has(product))violations.push(app+': Windows storage product name must be unique');
  products.add(product);
  if(app==='core'&&product!=='easyprivacy')violations.push('Core Windows storage namespace changed without migration');
  const gradle=fs.readFileSync(path.join(root,'apps',app,'android/app/build.gradle.kts'),'utf8');
  const id=gradle.match(/applicationId\s*=\s*"([^"]+)"/)?.[1];
  if(!id||androidIds.has(id))violations.push(app+': Android application ID must be unique');
  androidIds.add(id);
  const expected=app==='core'?'org.easyprivacy.easyprivacy':'org.easyprivacy.'+app;
  if(id!==expected)violations.push(app+': Android identity does not match broker/migration contract');
}
if(violations.length){process.stderr.write(violations.join('\n')+'\n');process.exitCode=1;}
else process.stdout.write('Application runtime dependency boundaries passed.\n');
