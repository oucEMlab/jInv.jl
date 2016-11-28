using  jInv.Mesh
using  jInv.Utils
using  jInv.LinearSolvers
using  jInv.InverseSolve
using  EikonalInv
using  MAT
using  FWI
using  ForwardHelmholtz
using  Multigrid
#############################################################################################################

include("Drivers/readModelAndGenerateMeshMref.jl");
include("Drivers/prepareFWIDataFiles.jl");
include("Drivers/setupFWI.jl");

plotting = false;

if plotting
	using  PyPlot
end
#############################################################################################################
modelDir = pwd();
dataDir = pwd();
resultsDir = pwd();
########################################################################################################
m = readdlm(string(modelDir,"/SEGmodel2Dsalt.dat"));
m = m*1e-3;
m = m';

newSize       = [256,128];
pad     	     = 10;
ABLPad 		     = pad + 8;
jumpSrc 	 	 = 5
maxBatchSize     = 256;
omega   	 = [0.5,0.75,1.25,1.75]*2*pi;

offset  = ceil(Int64,(newSize[1]*(10.0/13.5)));
println("Offset is: ",offset)
domain = [0.0,13.5,0.0,4.2];

(m,Minv,mref,boundsHigh,boundsLow) = readModelAndGenerateMeshMref(m,pad,newSize,domain);

useFilesForFields = false;

# ###################################################################################################################
dataFilenamePrefix = string(dataDir,"/DATA_SEG",tuple((Minv.n+1)...));
resultsFilename = string(resultsDir,"/SEG");
#######################################################################################################################


if plotting
	limits = [1.5,4.5];
	figure(1,figsize = (22,10))
	plotModel(m,true,Minv,pad,limits);
	figure(2,figsize = (22,10))# ,figsize = (22,10)
	plotModel(mref,true,Minv,pad,limits);
	
	
	m_t,M_t = cutBoundaryLayer(mref,Minv,pad);
	writedlm(string(resultsFilename,tuple((M_t.n+1)...),"_mref.dat"),convert(Array{Float16},m_t));
	m_t,M_t = cutBoundaryLayer(m,Minv,pad);
	writedlm(string(resultsFilename,tuple((M_t.n+1)...),"_mtrue.dat"),convert(Array{Float16},m_t));
	m_t = 0;
	M_t = 0;
end

######################## DIRECT SOLVER #################################################

numCores 	= 16;
BLAS.set_num_threads(numCores);
Ainv = getMUMPSsolver([],0,0,2);
# Ainv = getJuliaSolver();
# Ainv = getPARsolver([],0,0,6);

##########################################################################################

println("omega*maximum(h): ",omega*maximum(Minv.h)*sqrt(maximum(1./(boundsLow.^2))));

# This is a list of workers for FWI. Ideally they should be on different machines.
workersFWI = [workers()[1]];
println("The workers that we allocate for FWI are:");
println(workersFWI)

prepareFWIDataFiles(m,Minv,mref,boundsHigh,boundsLow,dataFilenamePrefix,omega,one(Complex128)*ones(size(omega)), pad,ABLPad,jumpSrc,
					offset,workersFWI,maxBatchSize,Ainv,useFilesForFields);

(Q,P,pMis,SourcesSubInd,contDiv,Iact,sback,mref,boundsHigh,boundsLow,resultsFilename) = 
   setupFWI(m,dataFilenamePrefix,resultsFilename,plotting,workersFWI,maxBatchSize,Ainv,SSDFun,useFilesForFields);

########################################################################################################
# Setting up the inversion for slowness
########################################################################################################
function dump(mc,Dc,iter,pInv,PMis,resultsFilename)
	fullMc = slowSquaredToVelocity(reshape(Iact*pInv.modelfun(mc)[1] + sback,tuple((pInv.MInv.n+1)...)))[1];
	Temp = splitext(resultsFilename);
	if iter>0
		Temp = string(Temp[1],iter,Temp[2]);
	else
		Temp = resultsFilename;
	end
	if resultsFilename!=""
		writedlm(Temp,convert(Array{Float16},fullMc));
	end
	if plotting
		close(888);
		figure(888);
		plotModel(fullMc,true,false,[],0,[1.5,4.8],splitdir(Temp)[2]);
	end
end

mref 		= velocityToSlow(mref)[1];
t    		= copy(boundsLow);
boundsLow 	= velocityToSlow(boundsHigh)[1];
boundsHigh 	= velocityToSlow(t)[1]; t = 0;
modfun 		= slowToSlowSquared;


########################################################################################################
# Set up Inversion #################################################################################
########################################################################################################

maxStep=0.05*maximum(boundsHigh);

regparams = [1.0,1.0,1.0,1e-5];
regfun(m,mref,M) = wdiffusionRegNodal(m,mref,M,Iact=Iact,C=regparams);
cgit = 9; 
alpha = 1e-10;
pcgTol = 1e-1;
maxit = 10;

HesPrec = getSSORCGRegularizationPreconditioner(1.0,1e-5,1000);

pInv = getInverseParam(Minv,modfun,regfun,alpha,mref[:],boundsLow,boundsHigh,
                         maxStep=maxStep,pcgMaxIter=cgit,pcgTol=pcgTol,
						 minUpdate=1e-3, maxIter = maxit,HesPrec=HesPrec);
mc = copy(mref[:]);
mc,Dc = freqCont(mc, pInv, pMis,contDiv, 2, resultsFilename,dump,"Joint",1,1,"projGN");
mc,Dc = freqCont(mc, pInv, pMis,contDiv, 2, resultsFilename,dump,"Joint",2,2,"projGN");
mc,Dc = freqCont(mc, pInv, pMis,contDiv, 2, resultsFilename,dump,"Joint",3,3,"projGN");
##############################################################################################



