const https=require('https');
const SB='kevrfdjqyuhmgziqxuvs.supabase.co';
const KEY=process.env.SUPABASE_SECRET_KEY||Buffer.from('ZXlKaGJHY2lPaUpJVXpJMU5pSXNJblI1Y0NJNklrcFhWQ0o5LmV5SnBjM01pT2lKemRYQmhZbUZ6WlNJc0luSmxaaUk2SW10bGRuSm1aR3B4ZVhWb2JXZDZhWEY0ZFhaeklpd2ljbTlzWlNJNkluTmxjblpwWTJWZmNtOXNaU0lzSW1saGRDSTZNVGMzT0RVM056azVOeXdpWlhod0lqb3lNRGswTVRVek9UazNmUS5MNllmbmo3UXUxTFNacTRmeDE1dkRHSWZiZTJuX0pxQ19SWW0tWEhlS1gw','base64').toString();
exports.handler=async(event)=>{
  if(event.httpMethod==='OPTIONS')return{statusCode:200,headers:{'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'Content-Type,Authorization,apikey,Prefer','Access-Control-Allow-Methods':'GET,POST,PATCH,DELETE,OPTIONS'},body:''};
  const path=event.path.replace('/.netlify/functions/sb','/rest/v1');
  const qs=event.rawQuery?'?'+event.rawQuery:'';
  return new Promise(resolve=>{
    const opts={hostname:SB,port:443,path:path+qs,method:event.httpMethod,headers:{'Content-Type':'application/json','apikey':KEY,'Authorization':'Bearer '+KEY,'Prefer':event.headers['prefer']||event.headers['Prefer']||''}};
    const req=https.request(opts,res=>{let d='';res.on('data',c=>d+=c);res.on('end',()=>resolve({statusCode:res.statusCode,headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'Content-Type,Authorization,apikey,Prefer','Access-Control-Allow-Methods':'GET,POST,PATCH,DELETE,OPTIONS'},body:d}));});
    req.on('error',e=>resolve({statusCode:500,body:JSON.stringify({error:e.message})}));
    if(event.body)req.write(event.body);req.end();
  });
};
