/*
		2011 Takahiro Harada
*/

//#pragma OPENCL EXTENSION cl_amd_printf : enable
#pragma OPENCL EXTENSION cl_khr_local_int32_base_atomics : enable
#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable

typedef unsigned int u32;
#define GET_GROUP_IDX get_group_id(0)
#define GET_LOCAL_IDX get_local_id(0)
#define GET_GLOBAL_IDX get_global_id(0)
#define GET_GROUP_SIZE get_local_size(0)
#define GROUP_LDS_BARRIER barrier(CLK_LOCAL_MEM_FENCE)
#define GROUP_MEM_FENCE mem_fence(CLK_LOCAL_MEM_FENCE)
#define AtomInc(x) atom_inc(&(x))
#define AtomInc1(x, out) out = atom_inc(&(x))
#define AtomAdd(x, value) atom_add(&(x), value)

#define SELECT_UINT4( b, a, condition ) select( b,a,condition )


#define make_uint4 (uint4)
#define make_uint2 (uint2)
#define make_int2 (int2)

#define WG_SIZE 64
#define ELEMENTS_PER_WORK_ITEM (256/WG_SIZE)
#define BITS_PER_PASS 4
#define NUM_BUCKET (1<<BITS_PER_PASS)
typedef uchar u8;

//	this isn't optimization for VLIW. But just reducing writes. 
#define USE_2LEVEL_REDUCE 1

//#define CHECK_BOUNDARY 1

//#define NV_GPU 1


//	Cypress
#define nPerWI 16
//	Cayman
//#define nPerWI 20


typedef struct
{
	int m_n;
	int m_nWGs;
	int m_startBit;
	int m_nBlocksPerWG;
} ConstBuffer;

uint prefixScanVectorEx( uint4* data )
{
	u32 sum = 0;
	u32 tmp = data[0].x;
	data[0].x = sum;
	sum += tmp;
	tmp = data[0].y;
	data[0].y = sum;
	sum += tmp;
	tmp = data[0].z;
	data[0].z = sum;
	sum += tmp;
	tmp = data[0].w;
	data[0].w = sum;
	sum += tmp;
	return sum;
}

u32 localPrefixSum( u32 pData, uint lIdx, uint* totalSum, __local u32 sorterSharedMemory[], int wgSize /*64 or 128*/ )
{
	{	//	Set data
		sorterSharedMemory[lIdx] = 0;
		sorterSharedMemory[lIdx+wgSize] = pData;
	}

	GROUP_LDS_BARRIER;

	{	//	Prefix sum
		int idx = 2*lIdx + (wgSize+1);
#if defined(USE_2LEVEL_REDUCE)
		if( lIdx < 64 )
		{
			u32 u0, u1, u2;
			u0 = sorterSharedMemory[idx-3];
			u1 = sorterSharedMemory[idx-2];
			u2 = sorterSharedMemory[idx-1];
			AtomAdd( sorterSharedMemory[idx], u0+u1+u2 );			
			GROUP_MEM_FENCE;

			u0 = sorterSharedMemory[idx-12];
			u1 = sorterSharedMemory[idx-8];
			u2 = sorterSharedMemory[idx-4];
			AtomAdd( sorterSharedMemory[idx], u0+u1+u2 );			
			GROUP_MEM_FENCE;

			u0 = sorterSharedMemory[idx-48];
			u1 = sorterSharedMemory[idx-32];
			u2 = sorterSharedMemory[idx-16];
			AtomAdd( sorterSharedMemory[idx], u0+u1+u2 );			
			GROUP_MEM_FENCE;
			if( wgSize > 64 )
			{
				sorterSharedMemory[idx] += sorterSharedMemory[idx-64];
				GROUP_MEM_FENCE;
			}

			sorterSharedMemory[idx-1] += sorterSharedMemory[idx-2];
			GROUP_MEM_FENCE;
		}
#else
		if( lIdx < 64 )
		{
			sorterSharedMemory[idx] += sorterSharedMemory[idx-1];
			GROUP_MEM_FENCE;
			sorterSharedMemory[idx] += sorterSharedMemory[idx-2];			
			GROUP_MEM_FENCE;
			sorterSharedMemory[idx] += sorterSharedMemory[idx-4];
			GROUP_MEM_FENCE;
			sorterSharedMemory[idx] += sorterSharedMemory[idx-8];
			GROUP_MEM_FENCE;
			sorterSharedMemory[idx] += sorterSharedMemory[idx-16];
			GROUP_MEM_FENCE;
			sorterSharedMemory[idx] += sorterSharedMemory[idx-32];
			GROUP_MEM_FENCE;
			if( wgSize > 64 )
			{
				sorterSharedMemory[idx] += sorterSharedMemory[idx-64];
				GROUP_MEM_FENCE;
			}

			sorterSharedMemory[idx-1] += sorterSharedMemory[idx-2];
			GROUP_MEM_FENCE;
		}
#endif
	}

	GROUP_LDS_BARRIER;

	*totalSum = sorterSharedMemory[wgSize*2-1];
	u32 addValue = sorterSharedMemory[lIdx+wgSize-1];
	return addValue;
}

//__attribute__((reqd_work_group_size(128,1,1)))
uint4 localPrefixSum128V( uint4 pData, uint lIdx, uint* totalSum, __local u32 sorterSharedMemory[] )
{
	u32 s4 = prefixScanVectorEx( &pData );
	u32 rank = localPrefixSum( s4, lIdx, totalSum, sorterSharedMemory, 128 );
	return pData + make_uint4( rank, rank, rank, rank );
}


//__attribute__((reqd_work_group_size(64,1,1)))
uint4 localPrefixSum64V( uint4 pData, uint lIdx, uint* totalSum, __local u32 sorterSharedMemory[] )
{
	u32 s4 = prefixScanVectorEx( &pData );
	u32 rank = localPrefixSum( s4, lIdx, totalSum, sorterSharedMemory, 64 );
	return pData + make_uint4( rank, rank, rank, rank );
}

u32 unpack4Key( u32 key, int keyIdx ){ return (key>>(keyIdx*8)) & 0xff;}

u32 bit8Scan(u32 v)
{
	return (v<<8) + (v<<16) + (v<<24);
}

//===




#define MY_HISTOGRAM(idx) localHistogramMat[(idx)*WG_SIZE+lIdx]


__kernel
__attribute__((reqd_work_group_size(WG_SIZE,1,1)))
void StreamCountKernel( __global u32* gSrc, __global u32* histogramOut, ConstBuffer cb )
{
	__local u32 localHistogramMat[NUM_BUCKET*WG_SIZE];

	u32 gIdx = GET_GLOBAL_IDX;
	u32 lIdx = GET_LOCAL_IDX;
	u32 wgIdx = GET_GROUP_IDX;
	u32 wgSize = GET_GROUP_SIZE;
	const int startBit = cb.m_startBit;
	const int n = cb.m_n;
	const int nWGs = cb.m_nWGs;
	const int nBlocksPerWG = cb.m_nBlocksPerWG;

	for(int i=0; i<NUM_BUCKET; i++)
	{
		MY_HISTOGRAM(i) = 0;
	}

	GROUP_LDS_BARRIER;

	const int blockSize = ELEMENTS_PER_WORK_ITEM*WG_SIZE;
	u32 localKey;

	int nBlocks = (n)/blockSize - nBlocksPerWG*wgIdx;

	int addr = blockSize*nBlocksPerWG*wgIdx + ELEMENTS_PER_WORK_ITEM*lIdx;

	for(int iblock=0; iblock<min(nBlocksPerWG, nBlocks); iblock++, addr+=blockSize)
	{
		//	MY_HISTOGRAM( localKeys.x ) ++ is much expensive than atomic add as it requires read and write while atomics can just add on AMD
		//	Using registers didn't perform well. It seems like use localKeys to address requires a lot of alu ops
		//	AMD: AtomInc performs better while NV prefers ++
		for(int i=0; i<ELEMENTS_PER_WORK_ITEM; i++)
		{
#if defined(CHECK_BOUNDARY)
			if( addr+i < n )
#endif
			{
				localKey = (gSrc[addr+i]>>startBit) & 0xf;
#if defined(NV_GPU)
				MY_HISTOGRAM( localKey )++;
#else
				AtomInc( MY_HISTOGRAM( localKey ) );
#endif
			}
		}
	}
	
	if( lIdx < NUM_BUCKET )
	{
		u32 sum = 0;
		for(int i=0; i<GET_GROUP_SIZE; i++)
		{
			sum += localHistogramMat[lIdx*WG_SIZE+(i+lIdx)%GET_GROUP_SIZE];
		}
		histogramOut[lIdx*nWGs+wgIdx] = sum;
	}
}


#define nPerLane (nPerWI/4)

//	NUM_BUCKET*nWGs < 128*nPerWI
__kernel
__attribute__((reqd_work_group_size(128,1,1)))
void PrefixScanKernel( __global u32* wHistogram1, ConstBuffer cb )
{
	__local u32 ldsTopScanData[128*2];

	u32 lIdx = GET_LOCAL_IDX;
	u32 wgIdx = GET_GROUP_IDX;
	const int nWGs = cb.m_nWGs;

	u32 data[nPerWI];
	for(int i=0; i<nPerWI; i++)
	{
		data[i] = 0;
		if( (nPerWI*lIdx+i) < NUM_BUCKET*nWGs )
			data[i] = wHistogram1[nPerWI*lIdx+i];
	}

	uint4 myData = make_uint4(0,0,0,0);

	for(int i=0; i<nPerLane; i++)
	{
		myData.x += data[nPerLane*0+i];
		myData.y += data[nPerLane*1+i];
		myData.z += data[nPerLane*2+i];
		myData.w += data[nPerLane*3+i];
	}

	uint totalSum;
	uint4 scanned = localPrefixSum128V( myData, lIdx, &totalSum, ldsTopScanData );

//	for(int j=0; j<4; j++) //	somehow it introduces a lot of branches
	{	int j = 0;
		u32 sum = 0;
		for(int i=0; i<nPerLane; i++)
		{
			u32 tmp = data[nPerLane*j+i];
			data[nPerLane*j+i] = sum;
			sum += tmp;
		}
	}
	{	int j = 1;
		u32 sum = 0;
		for(int i=0; i<nPerLane; i++)
		{
			u32 tmp = data[nPerLane*j+i];
			data[nPerLane*j+i] = sum;
			sum += tmp;
		}
	}
	{	int j = 2;
		u32 sum = 0;
		for(int i=0; i<nPerLane; i++)
		{
			u32 tmp = data[nPerLane*j+i];
			data[nPerLane*j+i] = sum;
			sum += tmp;
		}
	}
	{	int j = 3;
		u32 sum = 0;
		for(int i=0; i<nPerLane; i++)
		{
			u32 tmp = data[nPerLane*j+i];
			data[nPerLane*j+i] = sum;
			sum += tmp;
		}
	}

	for(int i=0; i<nPerLane; i++)
	{
		data[nPerLane*0+i] += scanned.x;
		data[nPerLane*1+i] += scanned.y;
		data[nPerLane*2+i] += scanned.z;
		data[nPerLane*3+i] += scanned.w;
	}

	for(int i=0; i<nPerWI; i++)
	{
		wHistogram1[nPerWI*lIdx+i] = data[i];
	}
}

//	4 scan, 4 exchange
void sort4Bits(u32 sortData[4], int startBit, int lIdx, __local u32 ldsSortData[WG_SIZE*ELEMENTS_PER_WORK_ITEM+16])
{
	for(int bitIdx=0; bitIdx<BITS_PER_PASS; bitIdx++)
	{
		u32 mask = (1<<bitIdx);
		uint4 cmpResult = make_uint4( (sortData[0]>>startBit) & mask, (sortData[1]>>startBit) & mask, (sortData[2]>>startBit) & mask, (sortData[3]>>startBit) & mask );
		uint4 prefixSum = SELECT_UINT4( make_uint4(1,1,1,1), make_uint4(0,0,0,0), cmpResult != make_uint4(0,0,0,0) );
		u32 total;
		prefixSum = localPrefixSum64V( prefixSum, lIdx, &total, ldsSortData );
		{
			uint4 localAddr = make_uint4(lIdx*4+0,lIdx*4+1,lIdx*4+2,lIdx*4+3);
			uint4 dstAddr = localAddr - prefixSum + make_uint4( total, total, total, total );
			dstAddr = SELECT_UINT4( prefixSum, dstAddr, cmpResult != make_uint4(0, 0, 0, 0) );

			GROUP_LDS_BARRIER;

			ldsSortData[dstAddr.x] = sortData[0];
			ldsSortData[dstAddr.y] = sortData[1];
			ldsSortData[dstAddr.z] = sortData[2];
			ldsSortData[dstAddr.w] = sortData[3];

			GROUP_LDS_BARRIER;

			sortData[0] = ldsSortData[localAddr.x];
			sortData[1] = ldsSortData[localAddr.y];
			sortData[2] = ldsSortData[localAddr.z];
			sortData[3] = ldsSortData[localAddr.w];

			GROUP_LDS_BARRIER;
		}
	}
}

//	2 scan, 2 exchange
void sort4Bits1(u32 sortData[4], int startBit, int lIdx, __local u32* ldsSortData)
{
	for(uint ibit=0; ibit<BITS_PER_PASS; ibit+=2)
	{
		uint4 b = make_uint4((sortData[0]>>(startBit+ibit)) & 0x3, 
			(sortData[1]>>(startBit+ibit)) & 0x3, 
			(sortData[2]>>(startBit+ibit)) & 0x3, 
			(sortData[3]>>(startBit+ibit)) & 0x3);

		u32 key4;
		u32 sKeyPacked[4] = { 0, 0, 0, 0 };
		{
			sKeyPacked[0] |= 1<<(8*b.x);
			sKeyPacked[1] |= 1<<(8*b.y);
			sKeyPacked[2] |= 1<<(8*b.z);
			sKeyPacked[3] |= 1<<(8*b.w);

			key4 = sKeyPacked[0] + sKeyPacked[1] + sKeyPacked[2] + sKeyPacked[3];
		}

		u32 rankPacked;
		u32 sumPacked;
		{
			rankPacked = localPrefixSum( key4, lIdx, &sumPacked, ldsSortData, WG_SIZE );
		}

		GROUP_LDS_BARRIER;

		u32 newOffset[4] = { 0,0,0,0 };
		{
			u32 sumScanned = bit8Scan( sumPacked );

			u32 scannedKeys[4];
			scannedKeys[0] = 1<<(8*b.x);
			scannedKeys[1] = 1<<(8*b.y);
			scannedKeys[2] = 1<<(8*b.z);
			scannedKeys[3] = 1<<(8*b.w);
			{	//	4 scans at once
				u32 sum4 = 0;
				for(int ie=0; ie<4; ie++)
				{
					u32 tmp = scannedKeys[ie];
					scannedKeys[ie] = sum4;
					sum4 += tmp;
				}
			}

			{
				u32 sumPlusRank = sumScanned + rankPacked;
				{	u32 ie = b.x;
					scannedKeys[0] += sumPlusRank;
					newOffset[0] = unpack4Key( scannedKeys[0], ie );
				}
				{	u32 ie = b.y;
					scannedKeys[1] += sumPlusRank;
					newOffset[1] = unpack4Key( scannedKeys[1], ie );
				}
				{	u32 ie = b.z;
					scannedKeys[2] += sumPlusRank;
					newOffset[2] = unpack4Key( scannedKeys[2], ie );
				}
				{	u32 ie = b.w;
					scannedKeys[3] += sumPlusRank;
					newOffset[3] = unpack4Key( scannedKeys[3], ie );
				}
			}
		}


		GROUP_LDS_BARRIER;

		{
			ldsSortData[newOffset[0]] = sortData[0];
			ldsSortData[newOffset[1]] = sortData[1];
			ldsSortData[newOffset[2]] = sortData[2];
			ldsSortData[newOffset[3]] = sortData[3];

			GROUP_LDS_BARRIER;

			u32 dstAddr = 4*lIdx;
			sortData[0] = ldsSortData[dstAddr+0];
			sortData[1] = ldsSortData[dstAddr+1];
			sortData[2] = ldsSortData[dstAddr+2];
			sortData[3] = ldsSortData[dstAddr+3];

			GROUP_LDS_BARRIER;
		}
	}
}

#define SET_HISTOGRAM(setIdx, key) ldsSortData[(setIdx)*NUM_BUCKET+key]

__kernel
__attribute__((reqd_work_group_size(WG_SIZE,1,1)))
void SortAndScatterKernel( __global const u32* restrict gSrc, __global const u32* rHistogram, __global u32* restrict gDst, ConstBuffer cb )
{
	__local u32 ldsSortData[WG_SIZE*ELEMENTS_PER_WORK_ITEM+16];
	__local u32 localHistogramToCarry[NUM_BUCKET];
	__local u32 localHistogram[NUM_BUCKET*2];

	u32 gIdx = GET_GLOBAL_IDX;
	u32 lIdx = GET_LOCAL_IDX;
	u32 wgIdx = GET_GROUP_IDX;
	u32 wgSize = GET_GROUP_SIZE;

	const int n = cb.m_n;
	const int nWGs = cb.m_nWGs;
	const int startBit = cb.m_startBit;
	const int nBlocksPerWG = cb.m_nBlocksPerWG;

	if( lIdx < (NUM_BUCKET) )
	{
		localHistogramToCarry[lIdx] = rHistogram[lIdx*nWGs + wgIdx];
	}

	GROUP_LDS_BARRIER;

	const int blockSize = ELEMENTS_PER_WORK_ITEM*WG_SIZE;

	int nBlocks = n/blockSize - nBlocksPerWG*wgIdx;

	int addr = blockSize*nBlocksPerWG*wgIdx + ELEMENTS_PER_WORK_ITEM*lIdx;

	for(int iblock=0; iblock<min(nBlocksPerWG, nBlocks); iblock++, addr+=blockSize)
	{
		u32 myHistogram = 0;

		u32 sortData[ELEMENTS_PER_WORK_ITEM];
		for(int i=0; i<ELEMENTS_PER_WORK_ITEM; i++)
#if defined(CHECK_BOUNDARY)
			sortData[i] = ( addr+i < n )? gSrc[ addr+i ] : 0xffffffff;
#else
			sortData[i] = gSrc[ addr+i ];
#endif

		sort4Bits1(sortData, startBit, lIdx, ldsSortData);

		u32 keys[ELEMENTS_PER_WORK_ITEM];
		for(int i=0; i<ELEMENTS_PER_WORK_ITEM; i++)
			keys[i] = (sortData[i]>>startBit) & 0xf;

		{	//	create histogram
			u32 setIdx = lIdx/16;
			if( lIdx < NUM_BUCKET )
			{
				localHistogram[lIdx] = 0;
			}
			ldsSortData[lIdx] = 0;
			GROUP_LDS_BARRIER;

			for(int i=0; i<ELEMENTS_PER_WORK_ITEM; i++)
#if defined(CHECK_BOUNDARY)
				if( addr+i < n )
#endif
				AtomInc( SET_HISTOGRAM( setIdx, keys[i] ) );
			
			GROUP_LDS_BARRIER;
			
			uint hIdx = NUM_BUCKET+lIdx;
			if( lIdx < NUM_BUCKET )
			{
				u32 sum = 0;
				for(int i=0; i<WG_SIZE/16; i++)
				{
					sum += SET_HISTOGRAM( i, lIdx );
				}
				myHistogram = sum;
				localHistogram[hIdx] = sum;
			}
			GROUP_LDS_BARRIER;

#if defined(USE_2LEVEL_REDUCE)
			if( lIdx < NUM_BUCKET )
			{
				localHistogram[hIdx] = localHistogram[hIdx-1];
				GROUP_MEM_FENCE;

				u32 u0, u1, u2;
				u0 = localHistogram[hIdx-3];
				u1 = localHistogram[hIdx-2];
				u2 = localHistogram[hIdx-1];
				AtomAdd( localHistogram[hIdx], u0 + u1 + u2 );
				GROUP_MEM_FENCE;
				u0 = localHistogram[hIdx-12];
				u1 = localHistogram[hIdx-8];
				u2 = localHistogram[hIdx-4];
				AtomAdd( localHistogram[hIdx], u0 + u1 + u2 );
				GROUP_MEM_FENCE;
			}
#else
			if( lIdx < NUM_BUCKET )
			{
				localHistogram[hIdx] = localHistogram[hIdx-1];
				GROUP_MEM_FENCE;
				localHistogram[hIdx] += localHistogram[hIdx-1];
				GROUP_MEM_FENCE;
				localHistogram[hIdx] += localHistogram[hIdx-2];
				GROUP_MEM_FENCE;
				localHistogram[hIdx] += localHistogram[hIdx-4];
				GROUP_MEM_FENCE;
				localHistogram[hIdx] += localHistogram[hIdx-8];
				GROUP_MEM_FENCE;
			}
#endif
			GROUP_LDS_BARRIER;
		}

		{
			for(int ie=0; ie<ELEMENTS_PER_WORK_ITEM; ie++)
			{
				int dataIdx = ELEMENTS_PER_WORK_ITEM*lIdx+ie;
				int binIdx = keys[ie];
				int groupOffset = localHistogramToCarry[binIdx];
				int myIdx = dataIdx - localHistogram[NUM_BUCKET+binIdx];
#if defined(CHECK_BOUNDARY)
				if( addr+ie < n )
#endif
				gDst[ groupOffset + myIdx ] = sortData[ie];
			}
		}

		GROUP_LDS_BARRIER;

		if( lIdx < NUM_BUCKET )
		{
			localHistogramToCarry[lIdx] += myHistogram;
		}
		GROUP_LDS_BARRIER;
	}
}

